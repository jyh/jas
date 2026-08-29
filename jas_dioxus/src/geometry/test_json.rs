//! Canonical Test JSON serialization for cross-language equivalence testing.
//!
//! See `CROSS_LANGUAGE_TESTING.md` at the repository root for the full
//! specification.  Every semantic document value has exactly one JSON
//! string representation, so byte-for-byte comparison of the output is a
//! valid equivalence check.

use crate::document::artboard::{Artboard, ArtboardFill, ArtboardOptions};
use crate::document::document::{Document, ElementPath, ElementSelection, Selection, SelectionKind, SortedCps};
use crate::document::document_setup::DocumentSetup;
use crate::document::print_preferences::{
    artboard_range_mode_from, artboard_range_mode_str, media_size_from, media_size_str,
    orientation_from, orientation_str, print_layers_from, print_layers_str,
    printer_mark_type_from, printer_mark_type_str, scaling_mode_from,
    scaling_mode_str,
    output_mode_from, output_mode_str, emulsion_from, emulsion_str,
    image_polarity_from, image_polarity_str, dot_shape_from, dot_shape_str,
    font_download_from, font_download_str,
    postscript_level_from, postscript_level_str,
    data_format_from, data_format_str,
    color_handling_from, color_handling_str,
    rendering_intent_from, rendering_intent_str,
    flattener_preset_from, flattener_preset_str,
    Advanced, ColorManagement, Graphics, InkOverride, MarksAndBleed, Output,
    PrintPreferences,
};
use crate::geometry::element::*;

// ---------------------------------------------------------------------------
// Float formatting: round to 6 decimal places
//
// R3 (JYH, 2026-08-01). This was 4dp until 2026-08-02, which is the SAME
// quantizer the SVG writer uses for positions — so the oracle shared its
// subject's resolution and every divergence below 1e-4 was invisible BY
// CONSTRUCTION. The codec gates passed because they could not see, not because
// the ports agreed: the circularity law from `check_lane_coverage.py` (never
// derive a floor from the parse it guards) living inside a codec.
//
// SIX, and not more. Measured across the corpus: 9 and 12 buy nothing over 6 --
// identical file count, identical delta count, identical leaf set. A fixed 17
// breaks BOTH ports' readers, `serde_json` and `JSONSerialization` each
// mis-rounding 19-significant-digit literals by one ulp. And "shortest
// round-trip" is spelled three different ways by Rust, Swift and Python, so
// adopting it here would make byte-level float formatting a cross-language
// contract in the very layer that exists to detect contract breaks.
//
// UNIFORM, including the matrix multipliers `a`/`b`/`c`/`d`. An earlier
// amendment would have given those full precision here, on the argument that
// MATRIXPRECISION made the SVG writer infinitely fine for them and the oracle
// must be strictly finer than every writer. WITHDRAWN 2026-08-02, for two
// reasons that only appear when you read `svg.rs`:
//
//   1. `fmt_matrix_entry` states its scope and forbids exactly this -- "the two
//      `matrix(...)` writers below and nothing else ... would make byte-level
//      float formatting a cross-language contract in the very layer that exists
//      to detect contract breaks. DO NOT WIDEN IT." That layer is this file.
//   2. The property the amendment protected is ALREADY pinned, and harder than
//      any print precision can pin it: `matrix_multipliers_survive_a_save_and_
//      reopen_bit_exactly` and `a_reopened_matrix_is_bit_identical_on_every_
//      later_save_and_reopen` compare `to_bits()` over all 360 rotations. Raw
//      bits beat printed decimals at every precision. The oracle does not need
//      to carry a duty a dedicated test already discharges.
//
// So the oracle's job here is cross-port equivalence of computed documents,
// which 6dp serves, and matrix drift stays where its own tests already hold it.
// ---------------------------------------------------------------------------

fn fmt(v: f64) -> String {
    let rounded = (v * 1000000.0).round() / 1000000.0;
    // Ensure there is always a decimal point.
    if rounded == rounded.trunc() {
        format!("{:.1}", rounded)
    } else {
        // Format with enough decimals, strip trailing zeros but keep at
        // least one digit after the decimal point.
        let s = format!("{:.6}", rounded);
        let s = s.trim_end_matches('0');
        s.to_string()
    }
}

// ---------------------------------------------------------------------------
// String escaping
// ---------------------------------------------------------------------------

/// The canonical Test-JSON spelling of one string, quotes included.
///
/// Every string VALUE this file emits goes through here — element names and
/// ids, tspan content, enum tags, text-decoration members, recipe op names,
/// recorded input ids, concept params. Object KEYS deliberately do not: they
/// are compile-time literals in this file (`JsonObj::build`, the `partial`
/// wrapper in `selection_json`), never data, and routing them would suggest
/// otherwise. The one key that IS data — a recipe param's object key — does
/// go through here, in `canonical_value`.
///
/// Before 2026-07-27 there were three
/// different escaping levels in this one file, only one of which produced
/// JSON for a control character; the third (`canonical_value`'s `{:?}`) also
/// disagreed byte-for-byte with JasSwift's mirror on combining marks, ZWJ,
/// NBSP and soft hyphens. `test_fixtures/algorithms/canonical_json_string.json`
/// is the rule's whole contract and both ports run it.
///
/// The rule is Python's `json.dumps(s, ensure_ascii=False)` — the house
/// adjudication hierarchy's "absent a guiding principle, the reference
/// decides": short escapes for `\ "   \n \r \t`, `\u00xx` with
/// LOWER-CASE hex below U+0020, and every scalar at U+0020 and above emitted
/// literally (including U+007F, which JSON does not require escaping).
/// Solidus is not escaped.
pub fn json_escape_string(s: &str) -> String {
    let mut out = String::with_capacity(s.len() + 2);
    out.push('"');
    for c in s.chars() {
        match c {
            '"' => out.push_str("\\\""),
            '\\' => out.push_str("\\\\"),
            '\u{8}' => out.push_str("\\b"),
            '\u{c}' => out.push_str("\\f"),
            '\n' => out.push_str("\\n"),
            '\r' => out.push_str("\\r"),
            '\t' => out.push_str("\\t"),
            c if (c as u32) < 0x20 => {
                out.push_str(&format!("\\u{:04x}", c as u32));
            }
            c => out.push(c),
        }
    }
    out.push('"');
    out
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
        self.entries.push((key.to_string(), json_escape_string(v)));
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
                    .map(|s| json_escape_string(s))
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

/// Public canonicalizer (OP_LOG.md §10): canonical JSON of an arbitrary
/// serde_json value using the SAME sorted-key + fixed-float (`fmt`) rule the
/// document/recipe serializers use. Exposed so the cross-language
/// production-capture journal serializer pins op `params` byte-identically to
/// `document_to_test_json` floats (e.g. the marquee `x:-5.0` → `-5`).
pub fn canonical_json_value(v: &serde_json::Value) -> String {
    canonical_value(v)
}

/// Canonical JSON of an arbitrary serde_json value (sorted object keys, fixed
/// floats via `fmt`), so a recorded element's recipe `params` serialize
/// byte-identically (RECORDED_ELEMENTS.md §8 / OP_LOG.md §5 canonicalization).
fn canonical_value(v: &serde_json::Value) -> String {
    match v {
        serde_json::Value::Null => "null".to_string(),
        serde_json::Value::Bool(b) => b.to_string(),
        serde_json::Value::Number(n) => fmt(n.as_f64().unwrap_or(0.0)),
        // NOT `{s:?}`: Rust's Debug spells U+0000 `\0` and U+0001 `\u{1}`,
        // neither of which is JSON, and escapes every scalar Rust calls
        // non-printable (combining marks, ZWJ, NBSP, soft hyphen) where
        // JasSwift emitted them raw — a byte divergence on the params path.
        serde_json::Value::String(s) => json_escape_string(s),
        serde_json::Value::Array(a) => {
            json_array(&a.iter().map(canonical_value).collect::<Vec<_>>())
        }
        serde_json::Value::Object(m) => {
            let mut keys: Vec<&String> = m.keys().collect();
            keys.sort();
            let entries: Vec<String> = keys
                .iter()
                .map(|k| format!("{}:{}", json_escape_string(k), canonical_value(&m[*k])))
                .collect();
            format!("{{{}}}", entries.join(","))
        }
    }
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
            // The four stroke fields the canonical test JSON dropped by
            // construction until 2026-07-28 (see `extended_element_fields`).
            // Emitted only when non-default, per this file's
            // identity-omission convention, so a stroke that carries none of
            // them serializes byte-identically to before.
            if s.align != StrokeAlign::Center {
                o.str_val("align", stroke_align_str(s.align));
            }
            let dashes = s.dash_array();
            if !dashes.is_empty() {
                let items: Vec<String> = dashes.iter().map(|d| fmt(*d)).collect();
                o.raw("dash_pattern", json_array(&items));
            }
            if s.dash_align_anchors {
                o.bool_val("dash_align_anchors", true);
            }
            if s.miter_limit != 10.0 {
                o.num("miter_limit", s.miter_limit);
            }
            o.build()
        }
    }
}

fn stroke_align_str(a: StrokeAlign) -> &'static str {
    match a {
        StrokeAlign::Center => "center",
        StrokeAlign::Inside => "inside",
        StrokeAlign::Outside => "outside",
    }
}

/// Snake-case name for a blend mode. Mirrors `BlendMode`'s Swift `rawValue`
/// exactly, so the two ports emit the same token for the same mode.
fn blend_mode_str(m: BlendMode) -> &'static str {
    match m {
        BlendMode::Normal => "normal",
        BlendMode::Darken => "darken",
        BlendMode::Multiply => "multiply",
        BlendMode::ColorBurn => "color_burn",
        BlendMode::Lighten => "lighten",
        BlendMode::Screen => "screen",
        BlendMode::ColorDodge => "color_dodge",
        BlendMode::Overlay => "overlay",
        BlendMode::SoftLight => "soft_light",
        BlendMode::HardLight => "hard_light",
        BlendMode::Difference => "difference",
        BlendMode::Exclusion => "exclusion",
        BlendMode::Hue => "hue",
        BlendMode::Saturation => "saturation",
        BlendMode::Color => "color",
        BlendMode::Luminosity => "luminosity",
    }
}

fn gradient_type_str(t: GradientType) -> &'static str {
    match t {
        GradientType::Linear => "linear",
        GradientType::Radial => "radial",
        GradientType::Freeform => "freeform",
    }
}

fn gradient_method_str(m: GradientMethod) -> &'static str {
    match m {
        GradientMethod::Classic => "classic",
        GradientMethod::Smooth => "smooth",
        GradientMethod::Points => "points",
        GradientMethod::Lines => "lines",
    }
}

fn stroke_sub_mode_str(m: StrokeSubMode) -> &'static str {
    match m {
        StrokeSubMode::Within => "within",
        StrokeSubMode::Along => "along",
        StrokeSubMode::Across => "across",
    }
}

/// A gradient, in the ONE form both ports can write byte-identically.
///
/// A stop's colour is emitted as this file's shared colour OBJECT rather than
/// as a hex string, deliberately: jas_dioxus stores it as a `Color` (rgb / hsb
/// / cmyk with alpha) and JasSwift as a `"#rrggbb"` String, so hex is the
/// NARROWER of the two and writing it would silently flatten an hsb or
/// translucent Rust stop on the way out — a codec speaks to nothing, so it may
/// not narrow anything. The object form is lossless for every value either
/// port can hold; the cost is stated rather than hidden: a shared fixture can
/// only carry a stop colour JasSwift can express, because JasSwift's reader
/// converts the object back to hex.
fn gradient_json(g: &Gradient) -> String {
    let mut o = JsonObj::new();
    o.num("angle", g.angle);
    o.num("aspect_ratio", g.aspect_ratio);
    o.bool_val("dither", g.dither);
    o.str_val("method", gradient_method_str(g.method));
    let nodes: Vec<String> = g.nodes.iter().map(|n| {
        let mut n_o = JsonObj::new();
        n_o.raw("color", color_json(&n.color));
        n_o.num("opacity", n.opacity);
        n_o.num("spread", n.spread);
        n_o.num("x", n.x);
        n_o.num("y", n.y);
        n_o.build()
    }).collect();
    o.raw("nodes", json_array(&nodes));
    let stops: Vec<String> = g.stops.iter().map(|s| {
        let mut s_o = JsonObj::new();
        s_o.raw("color", color_json(&s.color));
        s_o.num("location", s.location);
        s_o.num("midpoint_to_next", s.midpoint_to_next);
        s_o.num("opacity", s.opacity);
        s_o.build()
    }).collect();
    o.raw("stops", json_array(&stops));
    o.str_val("stroke_sub_mode", stroke_sub_mode_str(g.stroke_sub_mode));
    o.str_val("type", gradient_type_str(g.gtype));
    o.build()
}

/// An opacity mask. The subtree is a FULL nested element, so the mask's own
/// artwork carries everything an element carries — including, recursively, a
/// mask of its own.
fn mask_json(m: &Mask) -> String {
    let mut o = JsonObj::new();
    o.bool_val("clip", m.clip);
    o.bool_val("disabled", m.disabled);
    o.bool_val("invert", m.invert);
    o.bool_val("linked", m.linked);
    o.raw("subtree", element_json(&m.subtree));
    o.raw("unlink_transform", transform_json(&m.unlink_transform));
    o.build()
}

fn width_points_json(pts: &[StrokeWidthPoint]) -> String {
    let items: Vec<String> = pts.iter().map(|p| {
        let mut o = JsonObj::new();
        o.num("t", p.t);
        o.num("width_left", p.width_left);
        o.num("width_right", p.width_right);
        o.build()
    }).collect();
    json_array(&items)
}

fn element_width_points(elem: &Element) -> &[StrokeWidthPoint] {
    match elem {
        Element::Line(e) => &e.width_points,
        Element::Path(e) => &e.width_points,
        _ => &[],
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
    let quoted: Vec<String> = parts.iter().map(|s| json_escape_string(s)).collect();
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
    // User-visible name from common.name. Layer emits its own name
    // field separately (Layer.name predates common.name); the Layer
    // arm uses common_fields_no_name() so we don't double-emit.
    match c.name.as_deref() {
        None => o.null("name"),
        Some(n) => o.str_val("name", n),
    }
    // Stable id is additive: emit only when set, so id-less elements
    // serialize byte-identically to before (keys are sorted on output).
    if let Some(id) = c.id.as_deref() {
        o.str_val("id", id);
    }
    o.num("opacity", c.opacity);
    o.raw("transform", transform_json(&c.transform));
    o.str_val("visibility", visibility_str(c.visibility));
}

/// Variant of `common_fields` that omits the optional name. Used by
/// Layer which carries its own required name field; emitting both
/// would produce a duplicate JSON key.
fn common_fields_no_name(o: &mut JsonObj, c: &CommonProps) {
    o.bool_val("locked", c.locked);
    if let Some(id) = c.id.as_deref() {
        o.str_val("id", id);
    }
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

/// The TWELVE fields the canonical test JSON dropped by construction until
/// 2026-07-28, emitted here for every element kind that can hold them.
///
/// WHY THIS EXISTS, and why it is not a nicety. Every document-level gate in
/// this repository — including THE PRESERVATION LAW's primary gate
/// (transcripts/EDIT_SEMANTICS_FREEZE.md §4.1/§4.2, "serialize before,
/// serialize after, diff") — snapshots this codec. A field the codec does not
/// emit is a field the law cannot range over: before 2026-07-28 an edit that
/// destroyed a BYSTANDER's mask, blend mode, dash pattern, stroke brush,
/// width profile or either gradient produced byte-identical canonical JSON
/// and the gate stayed green. The blindness was measured, not inferred: it is
/// the `test_json` column of test_fixtures/expected/codec_field_survival.json,
/// where all twelve read DROPPED while the BINARY codec's dropped set was a
/// strict SUBSET of it.
///
/// Every key is emitted CONDITIONALLY on being non-default, per this file's
/// identity-omission convention (the same rule `id` and `fill_rule` already
/// follow). That is what keeps an element carrying none of them serializing
/// byte-identically to before — and it is also what makes destruction
/// visible: a bystander whose mask is destroyed loses the key entirely, and
/// key-presence is part of the diff.
fn extended_element_fields(o: &mut JsonObj, elem: &Element) {
    let c = elem.common();
    if c.mode != BlendMode::Normal {
        o.str_val("mode", blend_mode_str(c.mode));
    }
    if let Some(m) = &c.mask {
        o.raw("mask", mask_json(m));
    }
    if let Some(t) = &c.tool_origin {
        o.str_val("tool_origin", t);
    }
    if let Some(g) = elem.fill_gradient() {
        o.raw("fill_gradient", gradient_json(g));
    }
    if let Some(g) = elem.stroke_gradient() {
        o.raw("stroke_gradient", gradient_json(g));
    }
    let wp = element_width_points(elem);
    if !wp.is_empty() {
        o.raw("width_points", width_points_json(wp));
    }
    if let Element::Path(e) = elem {
        if let Some(b) = &e.stroke_brush {
            o.str_val("stroke_brush", b);
        }
        if let Some(b) = &e.stroke_brush_overrides {
            o.str_val("stroke_brush_overrides", b);
        }
    }
    // The two CONTAINER-only flags (Opacity panel, transcripts/OPACITY.md
    // §Group). They live on Group and Layer and nowhere else, so they are
    // written here rather than beside the eleven common keys — and, like every
    // key above, only when true, which is what keeps every shipped golden
    // (whose containers are all false) byte-identical.
    let (iso, ko) = match elem {
        Element::Group(e) => (e.isolated_blending, e.knockout_group),
        Element::Layer(e) => (e.isolated_blending, e.knockout_group),
        _ => (false, false),
    };
    if iso {
        o.bool_val("isolated_blending", true);
    }
    if ko {
        o.bool_val("knockout_group", true);
    }
}

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
            // The carried rule is part of what a path MEANS, so a
            // golden that omits it cannot see a port filling a hole
            // (transcripts/BOOLEAN.md). Emitted only when it is not the
            // `nonzero` default, per this file's identity-omission
            // convention — so existing goldens are unchanged and only
            // multi-ring boolean results grow the key.
            if !matches!(
                e.fill_rule,
                crate::geometry::element::FillRule::NonZero
            ) {
                o.str_val("fill_rule", "evenodd");
            }
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
            // After Layer.name → common.name merge, Layer uses the
            // same nullable name path as every other element.
            common_fields(&mut o, &e.common);
            let children: Vec<String> = e.children.iter().map(|c| element_json(c)).collect();
            o.raw("children", json_array(&children));
        }
        Element::Live(v) => match v {
            crate::geometry::live::LiveVariant::CompoundShape(cs) => {
                o.str_val("type", "live");
                o.str_val("kind", "compound_shape");
                // `operation` was previously omitted (a round-trip bug, since
                // the reader had no live arm at all); now emitted so compound
                // shapes round-trip through test_json.
                o.str_val("operation", match cs.operation {
                    crate::geometry::live::CompoundOperation::Union => "union",
                    crate::geometry::live::CompoundOperation::SubtractFront => "subtract_front",
                    crate::geometry::live::CompoundOperation::Intersection => "intersection",
                    crate::geometry::live::CompoundOperation::Exclude => "exclude",
                });
                common_fields(&mut o, &cs.common);
                let children: Vec<String> = cs.operands.iter().map(|c| element_json(c)).collect();
                o.raw("children", json_array(&children));
            }
            crate::geometry::live::LiveVariant::Reference(r) => {
                o.str_val("type", "live");
                o.str_val("kind", "reference");
                o.str_val("target", &r.target.0);
                common_fields(&mut o, &r.common);
                // fill/stroke are emitted only when set; in Phase 1 references
                // carry none (paint inheritance default / Fork F2), matching how
                // compound omits its own paint here.
                //
                // Symbols P4 (SYMBOLS.md §4 / Fork F2): the instance `transform`
                // field (distinct from common.transform, which `common_fields`
                // emits as the `transform` key) is emitted as a separate
                // `instance_transform` key, and ONLY when set — omitting it when
                // None keeps existing reference fixtures byte-identical.
                if r.transform.is_some() {
                    o.raw("instance_transform", transform_json(&r.transform));
                }
            }
            crate::geometry::live::LiveVariant::Recorded(rec) => {
                o.str_val("type", "live");
                o.str_val("kind", "recorded");
                common_fields(&mut o, &rec.common);
                // Inputs (by id) and the normalized recipe ops, canonicalized so
                // the recorded element serializes byte-identically across apps.
                let inputs: Vec<String> =
                    rec.inputs.iter().map(|i| json_escape_string(&i.0)).collect();
                o.raw("inputs", json_array(&inputs));
                let ops: Vec<String> = rec.ops.iter().map(|op| {
                    let targets: Vec<String> =
                        op.targets.iter().map(|t| json_escape_string(t)).collect();
                    format!(
                        "{{\"op\":{},\"params\":{},\"targets\":{}}}",
                        json_escape_string(&op.op),
                        canonical_value(&op.params),
                        json_array(&targets)
                    )
                }).collect();
                o.raw("ops", json_array(&ops));
            }
            crate::geometry::live::LiveVariant::Generated(ge) => {
                o.str_val("type", "live");
                o.str_val("kind", "generated");
                common_fields(&mut o, &ge.common);
                o.str_val("concept", &ge.concept_id);
                // params canonicalized so the element serializes byte-identically
                // across apps (sorted keys, fixed floats).
                o.raw("params", canonical_value(&ge.params));
            }
        },
    }
    extended_element_fields(&mut o, elem);
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
    // EMISSION ORDER IS THE SELECTION'S OWN ORDER — deliberately NOT sorted.
    //
    // This serializer used to sort by path, and that sort is why the shared
    // corpus was structurally blind to the D6 defect (LAYER_STRUCTURE.md §10):
    // JasSwift's `Selection` was a `Set`, so its iteration order was per-process
    // hash order, and every golden agreed anyway because BOTH ports sorted on
    // the way out. Selection order is artwork — it decides the z-order of what a
    // copy emits — so the canonical JSON must show it.
    //
    // Dropping the sort also makes a DUPLICATE entry visible: `Selection` is a
    // `Vec`/array in both ports now, so dedup is a manual guard at every
    // insertion site and a missing one shows up here as a repeated path.
    let items: Vec<String> = entries.drain(..).map(|(_, json)| json).collect();
    json_array(&items)
}

// ---------------------------------------------------------------------------
// Document serializer (public API)
// ---------------------------------------------------------------------------

/// Serialize a single Artboard to canonical JSON. Field order is
/// alphabetical (id, name, ...); the shared `JsonObj` builder sorts.
fn artboard_json(ab: &Artboard) -> String {
    let mut o = JsonObj::new();
    o.str_val("id", &ab.id);
    o.str_val("name", &ab.name);
    o.num("x", ab.x);
    o.num("y", ab.y);
    o.num("width", ab.width);
    o.num("height", ab.height);
    o.str_val("fill", &ab.fill.as_canonical());
    o.bool_val("show_center_mark", ab.show_center_mark);
    o.bool_val("show_cross_hairs", ab.show_cross_hairs);
    o.bool_val("show_video_safe_areas", ab.show_video_safe_areas);
    o.num("video_ruler_pixel_aspect_ratio", ab.video_ruler_pixel_aspect_ratio);
    o.build()
}

fn artboards_json(artboards: &[Artboard]) -> String {
    let items: Vec<String> = artboards.iter().map(artboard_json).collect();
    json_array(&items)
}

fn artboard_options_json(opts: &ArtboardOptions) -> String {
    let mut o = JsonObj::new();
    o.bool_val("fade_region_outside_artboard", opts.fade_region_outside_artboard);
    o.bool_val("update_while_dragging", opts.update_while_dragging);
    o.build()
}

fn document_setup_json(s: &DocumentSetup) -> String {
    let mut o = JsonObj::new();
    o.num("bleed_bottom", s.bleed_bottom);
    o.num("bleed_left", s.bleed_left);
    o.num("bleed_right", s.bleed_right);
    o.num("bleed_top", s.bleed_top);
    o.bool_val("bleed_uniform", s.bleed_uniform);
    o.bool_val("discard_white_overprint", s.discard_white_overprint);
    o.str_val("grid_color", &s.grid_color);
    o.num("grid_size", s.grid_size);
    o.bool_val("highlight_substituted_glyphs", s.highlight_substituted_glyphs);
    o.str_val("paper_color", &s.paper_color);
    o.bool_val("show_images_outline", s.show_images_outline);
    o.bool_val("simulate_colored_paper", s.simulate_colored_paper);
    o.str_val("transparency_flattener_preset",
              flattener_preset_str(&s.transparency_flattener_preset));
    o.build()
}

fn advanced_json(a: &Advanced) -> String {
    let mut o = JsonObj::new();
    o.str_val("overprint_flattener_preset",
              flattener_preset_str(&a.overprint_flattener_preset));
    o.bool_val("print_as_bitmap", a.print_as_bitmap);
    o.build()
}

fn color_management_json(c: &ColorManagement) -> String {
    let mut o = JsonObj::new();
    o.str_val("color_handling", color_handling_str(&c.color_handling));
    o.str_val("document_profile", &c.document_profile);
    o.bool_val("preserve_rgb_numbers", c.preserve_rgb_numbers);
    o.str_val("printer_profile", &c.printer_profile);
    o.str_val("rendering_intent", rendering_intent_str(&c.rendering_intent));
    o.build()
}

fn graphics_json(g: &Graphics) -> String {
    let mut o = JsonObj::new();
    o.bool_val("compatible_gradient_printing", g.compatible_gradient_printing);
    o.str_val("data_format", data_format_str(&g.data_format));
    o.num("flatness", g.flatness);
    o.str_val("font_download", font_download_str(&g.font_download));
    o.str_val("postscript_level", postscript_level_str(&g.postscript_level));
    o.num("raster_effects_resolution", g.raster_effects_resolution);
    o.build()
}

fn ink_override_json(ink: &InkOverride) -> String {
    let mut o = JsonObj::new();
    o.num("angle", ink.angle);
    o.str_val("dot_shape", dot_shape_str(&ink.dot_shape));
    o.num("frequency", ink.frequency);
    o.str_val("name", &ink.name);
    o.bool_val("print", ink.print);
    o.build()
}

fn inks_json(inks: &[InkOverride]) -> String {
    let items: Vec<String> = inks.iter().map(ink_override_json).collect();
    json_array(&items)
}

fn output_json(out: &Output) -> String {
    let mut o = JsonObj::new();
    o.bool_val("convert_spot_to_process", out.convert_spot_to_process);
    o.str_val("emulsion", emulsion_str(&out.emulsion));
    o.str_val("image_polarity", image_polarity_str(&out.image_polarity));
    o.raw("inks", inks_json(&out.inks));
    o.str_val("mode", output_mode_str(&out.mode));
    o.bool_val("overprint_black", out.overprint_black);
    o.str_val("printer_resolution", &out.printer_resolution);
    o.build()
}

fn marks_and_bleed_json(m: &MarksAndBleed) -> String {
    let mut o = JsonObj::new();
    o.bool_val("all_printer_marks", m.all_printer_marks);
    o.num("bleed_bottom", m.bleed_bottom);
    o.num("bleed_left", m.bleed_left);
    o.num("bleed_right", m.bleed_right);
    o.num("bleed_top", m.bleed_top);
    o.bool_val("color_bars", m.color_bars);
    o.num("mark_offset", m.mark_offset);
    o.bool_val("page_information", m.page_information);
    o.str_val("printer_mark_type", printer_mark_type_str(&m.printer_mark_type));
    o.bool_val("registration_marks", m.registration_marks);
    o.num("trim_mark_weight", m.trim_mark_weight);
    o.bool_val("trim_marks", m.trim_marks);
    o.bool_val("use_document_bleed", m.use_document_bleed);
    o.build()
}

fn print_preferences_json(p: &PrintPreferences) -> String {
    let mut o = JsonObj::new();
    o.raw("advanced", advanced_json(&p.advanced));
    o.str_val("artboard_range", &p.artboard_range);
    o.str_val("artboard_range_mode", artboard_range_mode_str(&p.artboard_range_mode));
    o.bool_val("auto_rotate", p.auto_rotate);
    o.bool_val("collate", p.collate);
    o.raw("color_management", color_management_json(&p.color_management));
    o.int("copies", p.copies as usize);
    o.num("custom_scale", p.custom_scale);
    o.raw("graphics", graphics_json(&p.graphics));
    o.bool_val("ignore_artboards", p.ignore_artboards);
    o.raw("marks_and_bleed", marks_and_bleed_json(&p.marks_and_bleed));
    o.num("media_height", p.media_height);
    o.str_val("media_size", media_size_str(&p.media_size));
    o.num("media_width", p.media_width);
    o.str_val("orientation", orientation_str(&p.orientation));
    o.raw("output", output_json(&p.output));
    o.num("placement_x", p.placement_x);
    o.num("placement_y", p.placement_y);
    o.str_val("preset_name", &p.preset_name);
    o.str_val("print_layers", print_layers_str(&p.print_layers));
    match &p.printer_name {
        Some(s) => o.str_val("printer_name", s),
        None => o.raw("printer_name", "null".to_string()),
    }
    o.bool_val("reverse_order", p.reverse_order);
    o.str_val("scaling_mode", scaling_mode_str(&p.scaling_mode));
    o.bool_val("skip_blank_artboards", p.skip_blank_artboards);
    o.num("tile_overlap_h", p.tile_overlap_h);
    o.num("tile_overlap_v", p.tile_overlap_v);
    o.str_val("tile_range", &p.tile_range);
    o.bool_val("transverse", p.transverse);
    o.build()
}

/// Serialize a Document to canonical test JSON.
///
/// The output is a compact JSON string with sorted keys and normalized
/// floats, suitable for byte-for-byte cross-language comparison.
///
/// Artboards and artboard_options are **omitted** from the output when
/// they carry their defaults (empty list, default options) so that
/// the byte-for-byte contract with legacy Python fixtures (which
/// predate the artboards feature) still holds. Native docs authored
/// with artboards or non-default options serialize them explicitly.
pub fn document_to_test_json(doc: &Document) -> String {
    let layers: Vec<String> = doc.layers.iter().map(|l| element_json(l)).collect();
    let mut o = JsonObj::new();
    if doc.artboard_options != ArtboardOptions::default() {
        o.raw("artboard_options", artboard_options_json(&doc.artboard_options));
    }
    if !doc.artboards.is_empty() {
        o.raw("artboards", artboards_json(&doc.artboards));
    }
    if doc.document_setup != DocumentSetup::default() {
        o.raw("document_setup", document_setup_json(&doc.document_setup));
    }
    o.raw("layers", json_array(&layers));
    if doc.print_preferences != PrintPreferences::default() {
        o.raw("print_preferences", print_preferences_json(&doc.print_preferences));
    }
    o.int("selected_layer", doc.selected_layer);
    o.raw("selection", selection_json(&doc.selection));
    // Symbols (master store, SYMBOLS.md §5): emit only when non-empty so
    // existing fixtures stay byte-identical, mirroring print_preferences /
    // artboards. Masters are sorted by common.id (the §2 deterministic-order
    // rule); an id-less master sorts as the empty string.
    if !doc.symbols.is_empty() {
        o.raw("symbols", symbols_json(&doc.symbols));
    }
    o.build()
}

/// Serialize the master store as a sorted-by-id JSON array of element JSON.
/// Sorting is on `common.id` (id-less masters sort as the empty string) so
/// the output is deterministic regardless of storage order (SYMBOLS.md §2).
fn symbols_json(symbols: &[Element]) -> String {
    let mut sorted: Vec<&Element> = symbols.iter().collect();
    sorted.sort_by(|a, b| {
        a.common().id.as_deref().unwrap_or("")
            .cmp(b.common().id.as_deref().unwrap_or(""))
    });
    let items: Vec<String> = sorted.iter().map(|m| element_json(m)).collect();
    json_array(&items)
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

/// A Test-JSON tspan `id`: the number's value when that value is an id in the
/// declared domain, else 0.
///
/// `CROSS_LANGUAGE_TESTING.md`'s Tspan notes declare `id` a monotonic `u32`.
/// Nothing in that file gives a meaning to a value outside the domain, so each
/// one reads as 0 — the answer both ports already gave for a negative, missing
/// or non-numeric id. Deliberately NOT the older `as_u64().unwrap_or(0) as u32`:
///
///   - `as_u64()` is `None` for ANY serde_json float, whole-valued or not, so
///     `3.0` read as 0 here and as 3 in JasSwift. The rule that would make a
///     decimal point meaningful ("Floats … always written with the decimal
///     point") is one of that file's Normalization rules, which are stated for
///     `document_to_test_json` — they bind the WRITER, not this reader.
///   - `as u32` on an in-`u64` value TRUNCATES to the low 32 bits, so
///     `4294967297` read as 1 — an id the writer could equally have emitted for
///     a real tspan, which TSPAN.md's Invariants require to be unique within one
///     `Text`. That truncation is an artifact of `as`, not an authored rule.
///
/// Gated in both ports by `test_fixtures/algorithms/tspan_id_from_json.json`.
fn parse_tspan_id(v: &serde_json::Value) -> u32 {
    let d = match v.as_f64() {
        Some(d) => d,
        None => return 0,
    };
    if !(d >= 0.0 && d <= 4_294_967_295.0) {
        return 0;
    }
    if d != d.trunc() {
        return 0;
    }
    d as u32
}

fn parse_tspan(v: &serde_json::Value) -> crate::geometry::tspan::Tspan {
    crate::geometry::tspan::Tspan {
        id: parse_tspan_id(&v["id"]),
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
    // The four extended stroke keys (absent ⇒ the default, matching the
    // writer's identity-omission convention). These were hard-coded to
    // defaults here until 2026-07-28, which is why a dashed, inside-aligned
    // stroke came back solid and centred.
    let align = match v["align"].as_str().unwrap_or("center") {
        "inside" => StrokeAlign::Inside,
        "outside" => StrokeAlign::Outside,
        _ => StrokeAlign::Center,
    };
    let mut dash_pattern = [0.0f64; 6];
    let mut dash_len: u8 = 0;
    if let Some(arr) = v["dash_pattern"].as_array() {
        for (i, d) in arr.iter().take(6).enumerate() {
            dash_pattern[i] = parse_f(d);
            dash_len = (i + 1) as u8;
        }
    }
    Some(Stroke {
        color: parse_color(&v["color"]),
        width: parse_f(&v["width"]),
        linecap: lc,
        linejoin: lj,
        miter_limit: v["miter_limit"].as_f64().unwrap_or(10.0),
        align,
        dash_pattern,
        dash_len,
        dash_align_anchors: v["dash_align_anchors"].as_bool().unwrap_or(false),
        // ARROWHEADS ARE STILL DROPPED. `start_arrow`, `end_arrow`, the two
        // scales and `arrow_align` are the same shape of blindness this wave
        // closed for the four fields above, and they are NOT in the shipped
        // matrix's `fields` list, so nothing measures them in any codec.
        // Carrying them here without measuring the binary and SVG columns
        // would be a claim wider than the evidence, so they are BANKED, named:
        // add the five rows to test_fixtures/expected/codec_field_survival.json
        // and close whichever codecs then read DROPPED.
        start_arrow: Arrowhead::None,
        end_arrow: Arrowhead::None,
        start_arrow_scale: 100.0,
        end_arrow_scale: 100.0,
        arrow_align: ArrowAlign::TipAtEnd,
        opacity: v["opacity"].as_f64().unwrap_or(1.0),
    })
}

fn parse_blend_mode(v: &serde_json::Value) -> BlendMode {
    match v.as_str().unwrap_or("normal") {
        "darken" => BlendMode::Darken,
        "multiply" => BlendMode::Multiply,
        "color_burn" => BlendMode::ColorBurn,
        "lighten" => BlendMode::Lighten,
        "screen" => BlendMode::Screen,
        "color_dodge" => BlendMode::ColorDodge,
        "overlay" => BlendMode::Overlay,
        "soft_light" => BlendMode::SoftLight,
        "hard_light" => BlendMode::HardLight,
        "difference" => BlendMode::Difference,
        "exclusion" => BlendMode::Exclusion,
        "hue" => BlendMode::Hue,
        "saturation" => BlendMode::Saturation,
        "color" => BlendMode::Color,
        "luminosity" => BlendMode::Luminosity,
        _ => BlendMode::Normal,
    }
}

fn parse_gradient(v: &serde_json::Value) -> Option<Box<Gradient>> {
    let obj = v.as_object()?;
    let _ = obj;
    Some(Box::new(Gradient {
        gtype: match v["type"].as_str().unwrap_or("linear") {
            "radial" => GradientType::Radial,
            "freeform" => GradientType::Freeform,
            _ => GradientType::Linear,
        },
        angle: parse_f(&v["angle"]),
        aspect_ratio: v["aspect_ratio"].as_f64().unwrap_or(100.0),
        method: match v["method"].as_str().unwrap_or("classic") {
            "smooth" => GradientMethod::Smooth,
            "points" => GradientMethod::Points,
            "lines" => GradientMethod::Lines,
            _ => GradientMethod::Classic,
        },
        dither: v["dither"].as_bool().unwrap_or(false),
        stroke_sub_mode: match v["stroke_sub_mode"].as_str().unwrap_or("within") {
            "along" => StrokeSubMode::Along,
            "across" => StrokeSubMode::Across,
            _ => StrokeSubMode::Within,
        },
        stops: v["stops"].as_array().unwrap_or(&vec![]).iter().map(|s| GradientStop {
            color: parse_color(&s["color"]),
            opacity: s["opacity"].as_f64().unwrap_or(100.0),
            location: parse_f(&s["location"]),
            midpoint_to_next: s["midpoint_to_next"].as_f64().unwrap_or(50.0),
        }).collect(),
        nodes: v["nodes"].as_array().unwrap_or(&vec![]).iter().map(|n| GradientNode {
            x: parse_f(&n["x"]),
            y: parse_f(&n["y"]),
            color: parse_color(&n["color"]),
            opacity: n["opacity"].as_f64().unwrap_or(100.0),
            spread: n["spread"].as_f64().unwrap_or(25.0),
        }).collect(),
    }))
}

fn parse_mask(v: &serde_json::Value) -> Option<Box<Mask>> {
    let obj = v.as_object()?;
    let _ = obj;
    Some(Box::new(Mask {
        subtree: Box::new(parse_element(&v["subtree"])),
        clip: v["clip"].as_bool().unwrap_or(true),
        invert: v["invert"].as_bool().unwrap_or(false),
        disabled: v["disabled"].as_bool().unwrap_or(false),
        linked: v["linked"].as_bool().unwrap_or(true),
        unlink_transform: parse_transform_opt(&v["unlink_transform"]),
    }))
}

fn parse_width_points(v: &serde_json::Value) -> Vec<StrokeWidthPoint> {
    v.as_array().unwrap_or(&vec![]).iter().map(|p| StrokeWidthPoint {
        t: parse_f(&p["t"]),
        width_left: parse_f(&p["width_left"]),
        width_right: parse_f(&p["width_right"]),
    }).collect()
}

/// Read back the twelve extended fields `extended_element_fields` writes.
/// Kept as a post-pass over the built element rather than threaded through
/// the eight struct literals below: every kind that can hold a field gets it
/// from ONE place, so a new element kind cannot silently miss one.
fn apply_extended_element_fields(elem: &mut Element, v: &serde_json::Value) {
    let c = elem.common_mut();
    c.mode = parse_blend_mode(&v["mode"]);
    c.mask = parse_mask(&v["mask"]);
    let fg = parse_gradient(&v["fill_gradient"]);
    let sg = parse_gradient(&v["stroke_gradient"]);
    let wp = parse_width_points(&v["width_points"]);
    match elem {
        Element::Line(e) => {
            e.stroke_gradient = sg;
            e.width_points = wp;
        }
        Element::Rect(e) => { e.fill_gradient = fg; e.stroke_gradient = sg; }
        Element::Ellipse(e) => { e.fill_gradient = fg; e.stroke_gradient = sg; }
        Element::Polyline(e) => { e.fill_gradient = fg; e.stroke_gradient = sg; }
        Element::Polygon(e) => { e.fill_gradient = fg; e.stroke_gradient = sg; }
        Element::Path(e) => {
            e.fill_gradient = fg;
            e.stroke_gradient = sg;
            e.width_points = wp;
            e.stroke_brush = parse_str_opt(&v["stroke_brush"]);
            e.stroke_brush_overrides = parse_str_opt(&v["stroke_brush_overrides"]);
        }
        // The container-only flags. The `group` / `layer` arms of
        // `parse_element_base` still build with `false`, exactly as
        // `parse_common` still builds with the default blend mode: this
        // post-pass is the ONE place either flag is read, so a new container
        // kind cannot silently miss it.
        Element::Group(e) => {
            e.isolated_blending = v["isolated_blending"].as_bool().unwrap_or(false);
            e.knockout_group = v["knockout_group"].as_bool().unwrap_or(false);
        }
        Element::Layer(e) => {
            e.isolated_blending = v["isolated_blending"].as_bool().unwrap_or(false);
            e.knockout_group = v["knockout_group"].as_bool().unwrap_or(false);
        }
        _ => {}
    }
}

/// Public so the `algorithm_roundtrip` harness can read a fixture's
/// `layer_transform` (the `element_evaluated_bounds` family's ancestor leg)
/// through the SAME parser the element's own `transform` goes through.
pub fn parse_transform(v: &serde_json::Value) -> Option<Transform> {
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
        mode: crate::geometry::element::BlendMode::default(),
        transform: parse_transform(&v["transform"]),
        locked: v["locked"].as_bool().unwrap_or(false),
        visibility: parse_visibility(&v["visibility"]),
        mask: None,
        tool_origin: v.get("tool_origin").and_then(|t| t.as_str()).map(String::from),
        name: v.get("name").and_then(|t| t.as_str()).map(String::from),
        id: v.get("id").and_then(|t| t.as_str()).map(String::from),
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
    let mut elem = parse_element_base(v);
    apply_extended_element_fields(&mut elem, v);
    elem
}

/// THIS READER IS STRICT ON PURPOSE, and the reason is the READER'S OWN.
///
/// An unknown `type` panics (see the fall-through arm below). In particular
/// a stray `"circle"` -- the kind the model lost on 2026-07-30, one round
/// kind, JYH -- is REFUSED here, even though [`crate::geometry::binary`]
/// still reads legacy TAG_CIRCLE because .bin is a persisted user format.
///
/// The strictness protects against a STALE FIXTURE INPUT being silently
/// REINTERPRETED. 51 goldens were rewritten that day; if one setup document
/// had kept `"type":"circle"` and this reader were tolerant, it would quietly
/// become a round ellipse and the test would PASS -- while testing something
/// other than what the fixture says it tests. A passing test that tests the
/// wrong thing is worse than a failing one.
///
/// THE REASON THIS COMMENT USED TO GIVE WAS WRONG, and it was refuted by
/// MEASUREMENT rather than spotted by reading: Flask (the Windows seat)
/// checked the corpus runners. They compare the produced canonical JSON as a
/// STRING against a pinned golden, so a port that kept WRITING
/// `"type":"circle"` fails on the string no matter what this reader tolerates.
/// The writer side was never the reader's job. Correction adopted 2026-07-30.
fn parse_element_base(v: &serde_json::Value) -> Element {
    let typ = v["type"].as_str().unwrap_or("");
    let common = parse_common(v);
    match typ {
        "line" => Element::Line(LineElem {
            x1: parse_f(&v["x1"]), y1: parse_f(&v["y1"]),
            x2: parse_f(&v["x2"]), y2: parse_f(&v["y2"]),
            stroke: parse_stroke(&v["stroke"]),
            width_points: vec![],
            common,
                    stroke_gradient: None,
        }),
        "rect" => Element::Rect(RectElem {
            x: parse_f(&v["x"]), y: parse_f(&v["y"]),
            width: parse_f(&v["width"]), height: parse_f(&v["height"]),
            rx: parse_f(&v["rx"]), ry: parse_f(&v["ry"]),
            fill: parse_fill(&v["fill"]), stroke: parse_stroke(&v["stroke"]),
            common,
                    fill_gradient: None,
            stroke_gradient: None,
        }),
        "ellipse" => Element::Ellipse(EllipseElem {
            cx: parse_f(&v["cx"]), cy: parse_f(&v["cy"]),
            rx: parse_f(&v["rx"]), ry: parse_f(&v["ry"]),
            fill: parse_fill(&v["fill"]), stroke: parse_stroke(&v["stroke"]),
            common,
                    fill_gradient: None,
            stroke_gradient: None,
        }),
        "polyline" => Element::Polyline(PolylineElem {
            points: parse_points(&v["points"]),
            fill: parse_fill(&v["fill"]), stroke: parse_stroke(&v["stroke"]),
            common,
                    fill_gradient: None,
            stroke_gradient: None,
        }),
        "polygon" => Element::Polygon(PolygonElem {
            points: parse_points(&v["points"]),
            fill: parse_fill(&v["fill"]), stroke: parse_stroke(&v["stroke"]),
            common,
                    fill_gradient: None,
            stroke_gradient: None,
        }),
        "path" => Element::Path(PathElem {
            d: parse_path_commands(&v["d"]),
            fill: parse_fill(&v["fill"]), stroke: parse_stroke(&v["stroke"]),
            width_points: vec![],
            common,
                    fill_gradient: None,
            stroke_gradient: None,
            stroke_brush: None,
            stroke_brush_overrides: None,
            // Absent means the `nonzero` default, matching the
            // serializer's identity-omission convention.
            fill_rule: if v["fill_rule"].as_str() == Some("evenodd") {
                crate::geometry::element::FillRule::EvenOdd
            } else {
                crate::geometry::element::FillRule::NonZero
            },
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
            Element::Group(GroupElem { children, common, isolated_blending: false, knockout_group: false })
        },
        "layer" => {
            let children = v["children"].as_array().unwrap_or(&vec![])
                .iter().map(|c| std::rc::Rc::new(parse_element(c))).collect();
            // common.name was already populated by parse_common from the
            // top-level "name" field — Layer no longer reads name itself.
            Element::Layer(LayerElem { children, common, isolated_blending: false, knockout_group: false })
        },
        "live" => {
            let kind = v["kind"].as_str().unwrap_or("");
            match kind {
                "compound_shape" => {
                    let operation = match v["operation"].as_str().unwrap_or("union") {
                        "subtract_front" => crate::geometry::live::CompoundOperation::SubtractFront,
                        "intersection" => crate::geometry::live::CompoundOperation::Intersection,
                        "exclude" => crate::geometry::live::CompoundOperation::Exclude,
                        _ => crate::geometry::live::CompoundOperation::Union,
                    };
                    let operands = v["children"].as_array().unwrap_or(&vec![])
                        .iter().map(|c| std::rc::Rc::new(parse_element(c))).collect();
                    Element::Live(crate::geometry::live::LiveVariant::CompoundShape(
                        crate::geometry::live::CompoundShape {
                            operation, operands, fill: None, stroke: None, common,
                        },
                    ))
                }
                "reference" => {
                    let target = crate::geometry::live::ElementRef(
                        v["target"].as_str().unwrap_or("").to_string());
                    let mut re = crate::geometry::live::ReferenceElem::new(target, common);
                    // Symbols P4: the instance `transform` field rides the
                    // `instance_transform` key (absent ⇒ None / null ⇒ None).
                    re.transform = parse_transform_opt(&v["instance_transform"]);
                    Element::Live(crate::geometry::live::LiveVariant::Reference(re))
                }
                "recorded" => {
                    // RECORDED_ELEMENTS.md §8. This arm did not exist until
                    // 2026-07-27: the writer emitted `"kind":"recorded"` and
                    // the reader panicked on it, so the codec could WRITE a
                    // shape it could not READ. Nothing noticed because the
                    // only recorded fixture (operations/recorded_eye.json) is
                    // a write-only pin — both ports BUILD the document in
                    // code and compare the serialization, never parsing one
                    // back. JasSwift has had all four arms all along.
                    let inputs = v["inputs"].as_array().unwrap_or(&vec![]).iter()
                        .filter_map(|i| i.as_str())
                        .map(|s| crate::geometry::live::ElementRef(s.to_string()))
                        .collect();
                    let ops = v["ops"].as_array().unwrap_or(&vec![]).iter()
                        .map(|o| crate::document::op_log::PrimitiveOp {
                            op: o["op"].as_str().unwrap_or("").to_string(),
                            params: o["params"].clone(),
                            targets: o["targets"].as_array().unwrap_or(&vec![]).iter()
                                .filter_map(|t| t.as_str().map(|s| s.to_string()))
                                .collect(),
                        })
                        .collect();
                    Element::Live(crate::geometry::live::LiveVariant::Recorded(
                        crate::geometry::live::RecordedElem::new(ops, inputs, common),
                    ))
                }
                "generated" => {
                    let concept_id = v["concept"].as_str().unwrap_or("").to_string();
                    let params = v["params"].clone();
                    Element::Live(crate::geometry::live::LiveVariant::Generated(
                        crate::geometry::live::GeneratedElem::new(concept_id, params, common),
                    ))
                }
                other => panic!("Unknown live kind: {}", other),
            }
        }
        // Strict by design -- a stale fixture is refused, never reinterpreted.
        // See the doc comment on this function for why (and for the reason it
        // does NOT give any more).
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
fn parse_artboard(v: &serde_json::Value) -> Artboard {
    Artboard {
        id: v["id"].as_str().unwrap_or("").to_string(),
        name: v["name"].as_str().unwrap_or("").to_string(),
        x: parse_f(&v["x"]),
        y: parse_f(&v["y"]),
        width: parse_f(&v["width"]),
        height: parse_f(&v["height"]),
        fill: ArtboardFill::from_canonical(v["fill"].as_str().unwrap_or("transparent")),
        show_center_mark: v["show_center_mark"].as_bool().unwrap_or(false),
        show_cross_hairs: v["show_cross_hairs"].as_bool().unwrap_or(false),
        show_video_safe_areas: v["show_video_safe_areas"].as_bool().unwrap_or(false),
        video_ruler_pixel_aspect_ratio: {
            let raw = parse_f(&v["video_ruler_pixel_aspect_ratio"]);
            if raw == 0.0 { 1.0 } else { raw }
        },
    }
}

fn parse_artboards(v: &serde_json::Value) -> Vec<Artboard> {
    // Missing key → return empty; the Document constructor applies the
    // at-least-one invariant separately. An empty array also takes the
    // invariant path at load time in the app layer.
    match v.as_array() {
        Some(arr) => arr.iter().map(parse_artboard).collect(),
        None => Vec::new(),
    }
}

fn parse_artboard_options(v: &serde_json::Value) -> ArtboardOptions {
    if v.is_null() || !v.is_object() {
        return ArtboardOptions::default();
    }
    ArtboardOptions {
        fade_region_outside_artboard: v["fade_region_outside_artboard"].as_bool().unwrap_or(true),
        update_while_dragging: v["update_while_dragging"].as_bool().unwrap_or(true),
    }
}

fn parse_document_setup(v: &serde_json::Value) -> DocumentSetup {
    if v.is_null() || !v.is_object() {
        return DocumentSetup::default();
    }
    let d = DocumentSetup::default();
    DocumentSetup {
        bleed_top: v["bleed_top"].as_f64().unwrap_or(d.bleed_top),
        bleed_right: v["bleed_right"].as_f64().unwrap_or(d.bleed_right),
        bleed_bottom: v["bleed_bottom"].as_f64().unwrap_or(d.bleed_bottom),
        bleed_left: v["bleed_left"].as_f64().unwrap_or(d.bleed_left),
        bleed_uniform: v["bleed_uniform"].as_bool().unwrap_or(d.bleed_uniform),
        show_images_outline: v["show_images_outline"].as_bool().unwrap_or(d.show_images_outline),
        highlight_substituted_glyphs: v["highlight_substituted_glyphs"].as_bool().unwrap_or(d.highlight_substituted_glyphs),
        grid_size: v["grid_size"].as_f64().unwrap_or(d.grid_size),
        grid_color: v["grid_color"].as_str().map(String::from).unwrap_or(d.grid_color),
        paper_color: v["paper_color"].as_str().map(String::from).unwrap_or(d.paper_color),
        simulate_colored_paper: v["simulate_colored_paper"].as_bool().unwrap_or(d.simulate_colored_paper),
        transparency_flattener_preset: v["transparency_flattener_preset"].as_str()
            .and_then(flattener_preset_from).unwrap_or(d.transparency_flattener_preset),
        discard_white_overprint: v["discard_white_overprint"].as_bool().unwrap_or(d.discard_white_overprint),
    }
}

fn parse_advanced(v: &serde_json::Value) -> Advanced {
    if v.is_null() || !v.is_object() {
        return Advanced::default();
    }
    let d = Advanced::default();
    Advanced {
        print_as_bitmap: v["print_as_bitmap"].as_bool().unwrap_or(d.print_as_bitmap),
        overprint_flattener_preset: v["overprint_flattener_preset"].as_str()
            .and_then(flattener_preset_from).unwrap_or(d.overprint_flattener_preset),
    }
}

fn parse_color_management(v: &serde_json::Value) -> ColorManagement {
    if v.is_null() || !v.is_object() {
        return ColorManagement::default();
    }
    let d = ColorManagement::default();
    ColorManagement {
        document_profile: v["document_profile"].as_str()
            .map(String::from).unwrap_or(d.document_profile),
        color_handling: v["color_handling"].as_str()
            .and_then(color_handling_from).unwrap_or(d.color_handling),
        printer_profile: v["printer_profile"].as_str()
            .map(String::from).unwrap_or(d.printer_profile),
        rendering_intent: v["rendering_intent"].as_str()
            .and_then(rendering_intent_from).unwrap_or(d.rendering_intent),
        preserve_rgb_numbers: v["preserve_rgb_numbers"].as_bool()
            .unwrap_or(d.preserve_rgb_numbers),
    }
}

fn parse_graphics(v: &serde_json::Value) -> Graphics {
    if v.is_null() || !v.is_object() {
        return Graphics::default();
    }
    let d = Graphics::default();
    Graphics {
        flatness: v["flatness"].as_f64().unwrap_or(d.flatness),
        font_download: v["font_download"].as_str()
            .and_then(font_download_from).unwrap_or(d.font_download),
        postscript_level: v["postscript_level"].as_str()
            .and_then(postscript_level_from).unwrap_or(d.postscript_level),
        data_format: v["data_format"].as_str()
            .and_then(data_format_from).unwrap_or(d.data_format),
        compatible_gradient_printing: v["compatible_gradient_printing"]
            .as_bool().unwrap_or(d.compatible_gradient_printing),
        raster_effects_resolution: v["raster_effects_resolution"]
            .as_f64().unwrap_or(d.raster_effects_resolution),
    }
}

fn parse_ink_override(v: &serde_json::Value) -> InkOverride {
    InkOverride {
        name: v["name"].as_str().map(String::from).unwrap_or_default(),
        print: v["print"].as_bool().unwrap_or(true),
        frequency: v["frequency"].as_f64().unwrap_or(75.0),
        angle: v["angle"].as_f64().unwrap_or(45.0),
        dot_shape: v["dot_shape"].as_str()
            .and_then(dot_shape_from)
            .unwrap_or(crate::document::print_preferences::DotShape::Round),
    }
}

fn parse_output(v: &serde_json::Value) -> Output {
    if v.is_null() || !v.is_object() {
        return Output::default();
    }
    let d = Output::default();
    let inks = match v["inks"].as_array() {
        Some(arr) => arr.iter().map(parse_ink_override).collect(),
        None => d.inks,
    };
    Output {
        mode: v["mode"].as_str().and_then(output_mode_from).unwrap_or(d.mode),
        emulsion: v["emulsion"].as_str().and_then(emulsion_from).unwrap_or(d.emulsion),
        image_polarity: v["image_polarity"].as_str()
            .and_then(image_polarity_from).unwrap_or(d.image_polarity),
        printer_resolution: v["printer_resolution"].as_str()
            .map(String::from).unwrap_or(d.printer_resolution),
        convert_spot_to_process: v["convert_spot_to_process"].as_bool()
            .unwrap_or(d.convert_spot_to_process),
        overprint_black: v["overprint_black"].as_bool().unwrap_or(d.overprint_black),
        inks,
    }
}

fn parse_marks_and_bleed(v: &serde_json::Value) -> MarksAndBleed {
    if v.is_null() || !v.is_object() {
        return MarksAndBleed::default();
    }
    let d = MarksAndBleed::default();
    MarksAndBleed {
        all_printer_marks: v["all_printer_marks"].as_bool().unwrap_or(d.all_printer_marks),
        trim_marks: v["trim_marks"].as_bool().unwrap_or(d.trim_marks),
        registration_marks: v["registration_marks"].as_bool().unwrap_or(d.registration_marks),
        color_bars: v["color_bars"].as_bool().unwrap_or(d.color_bars),
        page_information: v["page_information"].as_bool().unwrap_or(d.page_information),
        printer_mark_type: v["printer_mark_type"].as_str()
            .and_then(printer_mark_type_from).unwrap_or(d.printer_mark_type),
        trim_mark_weight: v["trim_mark_weight"].as_f64().unwrap_or(d.trim_mark_weight),
        mark_offset: v["mark_offset"].as_f64().unwrap_or(d.mark_offset),
        use_document_bleed: v["use_document_bleed"].as_bool().unwrap_or(d.use_document_bleed),
        bleed_top: v["bleed_top"].as_f64().unwrap_or(d.bleed_top),
        bleed_right: v["bleed_right"].as_f64().unwrap_or(d.bleed_right),
        bleed_bottom: v["bleed_bottom"].as_f64().unwrap_or(d.bleed_bottom),
        bleed_left: v["bleed_left"].as_f64().unwrap_or(d.bleed_left),
    }
}

fn parse_print_preferences(v: &serde_json::Value) -> PrintPreferences {
    if v.is_null() || !v.is_object() {
        return PrintPreferences::default();
    }
    let d = PrintPreferences::default();
    PrintPreferences {
        preset_name: v["preset_name"].as_str().map(String::from).unwrap_or(d.preset_name),
        printer_name: v["printer_name"].as_str().map(String::from),
        copies: v["copies"].as_u64().map(|n| n as u32).unwrap_or(d.copies),
        collate: v["collate"].as_bool().unwrap_or(d.collate),
        reverse_order: v["reverse_order"].as_bool().unwrap_or(d.reverse_order),
        artboard_range_mode: v["artboard_range_mode"].as_str()
            .and_then(artboard_range_mode_from).unwrap_or(d.artboard_range_mode),
        artboard_range: v["artboard_range"].as_str().map(String::from).unwrap_or(d.artboard_range),
        ignore_artboards: v["ignore_artboards"].as_bool().unwrap_or(d.ignore_artboards),
        skip_blank_artboards: v["skip_blank_artboards"].as_bool().unwrap_or(d.skip_blank_artboards),
        media_size: v["media_size"].as_str().and_then(media_size_from).unwrap_or(d.media_size),
        media_width: v["media_width"].as_f64().unwrap_or(d.media_width),
        media_height: v["media_height"].as_f64().unwrap_or(d.media_height),
        orientation: v["orientation"].as_str().and_then(orientation_from).unwrap_or(d.orientation),
        auto_rotate: v["auto_rotate"].as_bool().unwrap_or(d.auto_rotate),
        transverse: v["transverse"].as_bool().unwrap_or(d.transverse),
        print_layers: v["print_layers"].as_str().and_then(print_layers_from).unwrap_or(d.print_layers),
        placement_x: v["placement_x"].as_f64().unwrap_or(d.placement_x),
        placement_y: v["placement_y"].as_f64().unwrap_or(d.placement_y),
        scaling_mode: v["scaling_mode"].as_str().and_then(scaling_mode_from).unwrap_or(d.scaling_mode),
        custom_scale: v["custom_scale"].as_f64().unwrap_or(d.custom_scale),
        tile_overlap_h: v["tile_overlap_h"].as_f64().unwrap_or(d.tile_overlap_h),
        tile_overlap_v: v["tile_overlap_v"].as_f64().unwrap_or(d.tile_overlap_v),
        tile_range: v["tile_range"].as_str().map(String::from).unwrap_or(d.tile_range),
        marks_and_bleed: parse_marks_and_bleed(&v["marks_and_bleed"]),
        output: parse_output(&v["output"]),
        graphics: parse_graphics(&v["graphics"]),
        color_management: parse_color_management(&v["color_management"]),
        advanced: parse_advanced(&v["advanced"]),
    }
}

pub fn test_json_to_document(json: &str) -> Document {
    let v: serde_json::Value = serde_json::from_str(json)
        .expect("Failed to parse test JSON");
    let layers: Vec<Element> = v["layers"].as_array().unwrap()
        .iter().map(|l| parse_element(l)).collect();
    let selected_layer = v["selected_layer"].as_u64().unwrap_or(0) as usize;
    let selection = parse_selection(&v["selection"]);
    let artboards = parse_artboards(&v["artboards"]);
    let artboard_options = parse_artboard_options(&v["artboard_options"]);
    let document_setup = parse_document_setup(&v["document_setup"]);
    let print_preferences = parse_print_preferences(&v["print_preferences"]);
    // Symbols (master store): absent key → empty (legacy fixtures predate
    // symbols and stay byte-identical). Masters parse with the same
    // parse_element as layer content.
    let symbols: Vec<Element> = v["symbols"].as_array()
        .map(|arr| arr.iter().map(parse_element).collect())
        .unwrap_or_default();
    let doc = Document {
        layers,
        symbols,
        selected_layer,
        selection,
        artboards,
        artboard_options,
        document_setup,
        print_preferences,
    };
    // Enforce the unique-id invariant on import (first-pre-order-wins);
    // a no-op for well-formed (unique-id) documents. See REFERENCE_GRAPH.md §2.5.
    crate::geometry::normalize::dedupe_element_ids(&doc)
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

    /// CANONICAL TEST JSON IS STRICT, and that is a decision with a test now.
    ///
    /// The model lost its circle kind on 2026-07-30 (one round kind, JYH). The
    /// PERSISTED binary format stays read-tolerant — `TAG_CIRCLE` still loads,
    /// pinned by `binary.rs::a_legacy_circle_tag_still_reads_as_a_round_ellipse`,
    /// because a file saved the day before the migration must still open.
    ///
    /// This format is the opposite and deliberately so. It had no test: the
    /// strictness was real (`parse_element_base` ends in a panic) and nothing
    /// pinned it, so someone could add a `"circle" => Element::Ellipse(…)` arm
    /// "for compatibility" and no lane would red. That asymmetry — the
    /// forgiving half measured, the strict half only reasoned — is what this
    /// closes. Verified by adding exactly that arm: this test reds.
    ///
    /// **And the reason for strictness is not the one first written down.** The
    /// migration note said tolerance here "would let a port keep writing the old
    /// kind and it would read as agreement". It would not:
    /// `assert_operation_test` compares `actual != expected` — the emitted
    /// string against the pinned golden — so a port emitting `"type":"circle"`
    /// fails on the string whatever the reader accepts. The WRITER side was
    /// never the reader's job.
    ///
    /// What strictness actually buys is this: **a stale fixture INPUT is refused
    /// rather than silently reinterpreted.** 51 goldens were rewritten in that
    /// migration. A setup document that kept `"type":"circle"` would, under a
    /// tolerant reader, quietly become a round ellipse and the test would PASS
    /// while testing something other than what the fixture says. A passing test
    /// measuring the wrong thing is worse than a failing one.
    #[test]
    #[should_panic(expected = "Unknown element type: circle")]
    fn a_stale_circle_in_canonical_json_is_refused_not_reinterpreted() {
        let v: serde_json::Value = serde_json::from_str(
            r#"{"type":"circle","cx":36,"cy":36,"r":18}"#,
        ).unwrap();
        let _ = parse_element(&v);
    }

    /// The writer-side half of the same claim, so the pair is not left resting
    /// on the reader: a round ellipse SERIALISES as `ellipse`. This is what
    /// actually catches a port that kept the old kind — the golden comparison
    /// is a string comparison, and this is the string.
    #[test]
    fn a_round_ellipse_serialises_as_ellipse_never_as_circle() {
        let e = Element::Ellipse(EllipseElem {
            cx: 36.0, cy: 36.0, rx: 18.0, ry: 18.0,
            fill: None, stroke: None,
            common: CommonProps::default(),
            fill_gradient: None, stroke_gradient: None,
        });
        let mut doc = Document::default();
        doc.layers = vec![Element::Layer(LayerElem {
            children: vec![Rc::new(e)],
            common: CommonProps::default(),
            isolated_blending: false,
            knockout_group: false,
        })];
        let json = document_to_test_json(&doc);
        assert!(json.contains("\"type\":\"ellipse\""),
                "a round ellipse must serialise as ellipse: {json}");
        assert!(!json.contains("\"type\":\"circle\""),
                "nothing may emit the retired kind: {json}");
    }

    /// The corpus JSON boundary must round-trip the fill rule, not just
    /// emit it. The serializer has written `fill_rule` since the rule
    /// joined PathElem, but `parse_element` hardcoded NonZero — so a
    /// corpus vector COULD NOT express an even-odd path: any fixture
    /// declaring one would fail its own json -> doc -> json round trip.
    /// Symmetric with Swift (both ports emitted and neither parsed), so
    /// this was a write-only boundary rather than a parity break, and it
    /// is fixed in both ports together.
    ///
    /// Which corpus fixtures the fix could have moved, stated accurately
    /// because an earlier commit message got this wrong. THREE fixtures
    /// mention a fill rule today:
    ///
    ///   test_fixtures/actions/boolean_exclude_overlapping_rects_expected.json
    ///     declares `"fill_rule":"evenodd"` on its Path. Teaching the
    ///     PARSER to read the key cannot move it: `assert_action_test`
    ///     (cross_language_test.rs) compares
    ///     `document_to_test_json(result)` against the golden as TEXT and
    ///     never parses the golden back, so only the serializer's output
    ///     is under test and the serializer already emitted the key.
    ///   test_fixtures/algorithms/boolean.json and boolean_normalize.json
    ///     carry `a_fill_rule` / `b_fill_rule` (and `fill_rule`) as
    ///     algorithm-level OPERAND rules. Those are read by the algorithms
    ///     harness straight into a ruled polygon set, never through this
    ///     Path parser.
    ///
    /// The earlier claim was "no corpus fixture declares fill_rule today
    /// (grepped test_fixtures/expected/*.json)". The conclusion (no golden
    /// changes) survives, the evidence did not: `expected/` holds the
    /// SVG-parse goldens, which is the one family that has no fill_rule in
    /// it. Grep all of `test_fixtures/`, not one subdirectory.
    #[test]
    fn fill_rule_round_trips_through_test_json() {
        use crate::geometry::element::FillRule;
        for rule in [FillRule::NonZero, FillRule::EvenOdd] {
            let path = Element::Path(PathElem {
                d: vec![
                    PathCommand::MoveTo { x: 0.0, y: 0.0 },
                    PathCommand::LineTo { x: 10.0, y: 0.0 },
                    PathCommand::LineTo { x: 10.0, y: 10.0 },
                    PathCommand::ClosePath,
                ],
                fill: Some(Fill::new(Color::BLACK)),
                stroke: None,
                width_points: vec![],
                common: CommonProps::default(),
                fill_gradient: None,
                stroke_gradient: None,
                fill_rule: rule,
                stroke_brush: None,
                stroke_brush_overrides: None,
            });
            let layer = Element::Layer(LayerElem {
                children: vec![Rc::new(path)],
                isolated_blending: false,
                knockout_group: false,
                common: CommonProps::default(),
            });
            let doc = Document {
                layers: vec![layer], selected_layer: 0, ..Document::default()
            };
            let json = document_to_test_json(&doc);
            let back = test_json_to_document(&json);
            match &*back.layers[0].children().unwrap()[0] {
                Element::Path(p) => assert_eq!(p.fill_rule, rule,
                    "test_json dropped {rule:?}"),
                other => panic!("expected Path, got {other:?}"),
            }
            // Canonicality: the fixture form is a fixed point, which is
            // what every corpus golden comparison relies on.
            assert_eq!(document_to_test_json(&back), json);
        }
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
                    stroke_gradient: None,
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
                    fill_gradient: None,
            stroke_gradient: None,
        });
        let json = element_json(&rect);
        assert!(json.contains("\"type\":\"rect\""));
        assert!(json.contains("\"fill\":{\"color\":{\"a\":1.0,\"b\":0.0,\"g\":0.0,\"r\":1.0,\"space\":\"rgb\"},\"opacity\":1.0}"));
        assert!(json.contains("\"stroke\":null"));
    }

    #[test]
    fn common_id_round_trips() {
        // Stable identity (VISION.md §6.2): an element's id survives the
        // canonical test_json round-trip in the lead implementation.
        let elem = Element::Rect(RectElem {
            x: 0.0, y: 0.0, width: 10.0, height: 10.0, rx: 0.0, ry: 0.0,
            fill: None, stroke: None,
            common: CommonProps { id: Some("e1".to_string()), ..Default::default() },
            fill_gradient: None,
            stroke_gradient: None,
        });
        let json = element_json(&elem);
        assert!(json.contains("\"id\":\"e1\""), "id should serialize: {json}");
        let v: serde_json::Value = serde_json::from_str(&json).unwrap();
        let parsed = parse_element(&v);
        assert_eq!(parsed.common().id.as_deref(), Some("e1"));
    }

    #[test]
    fn id_absent_is_byte_identical() {
        // Additive invariant: an id-less element emits no "id" key, so
        // every existing document serializes exactly as before.
        let elem = Element::Rect(RectElem {
            x: 0.0, y: 0.0, width: 10.0, height: 10.0, rx: 0.0, ry: 0.0,
            fill: None, stroke: None,
            common: CommonProps::default(),
            fill_gradient: None,
            stroke_gradient: None,
        });
        let json = element_json(&elem);
        assert!(!json.contains("\"id\""), "id-less element must not emit id key: {json}");
    }

    /// R3 (JYH, 2026-08-01): the canonical-JSON oracle prints SIX decimals.
    ///
    /// The oracle must be strictly finer than every writer it adjudicates, and
    /// the writers quantize positions at 4dp. At 4dp the oracle shared the
    /// writer's quantizer, so a divergence below 1e-4 was invisible BY
    /// CONSTRUCTION — the gate passed because it could not see, not because the
    /// ports agreed.
    ///
    /// Six and not more: 9 and 12 buy nothing measurable over 6 on this corpus,
    /// and a fixed 17 breaks BOTH ports' readers — `serde_json` and
    /// `JSONSerialization` each mis-round 19-significant-digit literals by one
    /// ulp. Precision is not fidelity.
    #[test]
    fn float_formatting() {
        // Unchanged: integral values keep exactly one fractional digit.
        assert_eq!(fmt(1.0), "1.0");
        assert_eq!(fmt(0.0), "0.0");
        assert_eq!(fmt(72.0), "72.0");
        assert_eq!(fmt(0.5), "0.5");

        // THE CHANGE. These two were "3.1416" and "0.1235" at 4dp.
        assert_eq!(fmt(3.14159), "3.14159");
        assert_eq!(fmt(0.12345), "0.12345");

        // Rounding still happens — it happens two digits later.
        assert_eq!(fmt(3.14159265), "3.141593");
        assert_eq!(fmt(0.123456789), "0.123457");

        // The band the 4dp oracle could not resolve at all is now visible.
        // 1pt written to SVG as px at 4dp (4/3 -> 1.3333) and read back is
        // 1.3333 * 0.75 = 0.999975; at 4dp that printed as "1.0" and agreed
        // with a lossless 1.0 that had never crossed the conversion.
        assert_eq!(fmt(0.999975), "0.999975");
        assert_ne!(fmt(0.999975), fmt(1.0));

        // Trailing zeros are still stripped to one digit, now out to six.
        assert_eq!(fmt(2.5000004), "2.5");
        assert_eq!(fmt(1.100000), "1.1");
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
                    fill_gradient: None,
            stroke_gradient: None,
        });
        let json = element_json(&rect);
        // Keys must be in alphabetical order.
        let fill_pos = json.find("\"fill\"").unwrap();
        let height_pos = json.find("\"height\"").unwrap();
        let type_pos = json.find("\"type\"").unwrap();
        assert!(fill_pos < height_pos);
        assert!(height_pos < type_pos);
    }

    /// The serializer PRESERVES the selection's own order (it used to sort by
    /// path). Twin: JasSwift `selectionJsonPreservesEmissionOrder`.
    /// LAYER_STRUCTURE.md §10 D6 — the sort is what made the shared corpus
    /// blind to a `Set`-ordered selection.
    #[test]
    fn selection_json_preserves_emission_order() {
        let sel = vec![
            ElementSelection::all(vec![1, 0]),
            ElementSelection::all(vec![0, 1]),
            ElementSelection::partial(vec![0, 0], [2, 0, 4]),
        ];
        let json = selection_json(&sel);
        let pos_00 = json.find("[0,0]").unwrap();
        let pos_01 = json.find("[0,1]").unwrap();
        let pos_10 = json.find("[1,0]").unwrap();
        // Emitted in the order given, NOT [0,0] < [0,1] < [1,0].
        assert!(pos_10 < pos_01, "expected [1,0] first, got {json}");
        assert!(pos_01 < pos_00, "expected [0,1] second, got {json}");
    }

    /// A duplicate path is emitted TWICE — the serializer does not dedup, so a
    /// missing insertion guard is visible in every golden that carries a
    /// multi-entry selection. LAYER_STRUCTURE.md §10 D6 "THE MIGRATION HAZARD".
    #[test]
    fn selection_json_emits_a_duplicate_path_twice() {
        let sel = vec![
            ElementSelection::all(vec![0, 1]),
            ElementSelection::all(vec![0, 1]),
        ];
        let json = selection_json(&sel);
        assert_eq!(json.matches("[0,1]").count(), 2, "got {json}");
    }

    #[test]
    fn group_no_fill_stroke() {
        let group = Element::Group(GroupElem {
            children: Vec::new(),
            isolated_blending: false,
            knockout_group: false,
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

    // ----- Artboard serialization (ART-441 cross-app contract) -----

    fn make_artboard(id: &str, name: &str) -> Artboard {
        Artboard {
            id: id.to_string(),
            name: name.to_string(),
            ..Artboard::default_with_id(id.to_string())
        }
    }

    #[test]
    fn document_with_no_artboards_omits_keys() {
        // Fresh empty artboards list must not emit the new JSON keys,
        // preserving byte-for-byte compatibility with legacy Python
        // fixtures that predate artboards.
        let mut d = Document::default();
        d.artboards = Vec::new();
        let json = document_to_test_json(&d);
        assert!(!json.contains("\"artboards\""));
        assert!(!json.contains("\"artboard_options\""));
    }

    #[test]
    fn document_with_artboards_emits_them() {
        let mut d = Document::default();
        d.artboards = vec![make_artboard("aaa12345", "Artboard 1")];
        let json = document_to_test_json(&d);
        assert!(json.contains("\"artboards\":["));
        assert!(json.contains("\"id\":\"aaa12345\""));
        assert!(json.contains("\"name\":\"Artboard 1\""));
        assert!(json.contains("\"fill\":\"transparent\""));
    }

    #[test]
    fn artboards_roundtrip_preserves_ids() {
        let mut d = Document::default();
        d.artboards = vec![
            make_artboard("aaa00001", "Artboard 1"),
            make_artboard("bbb00002", "Cover"),
        ];
        let json1 = document_to_test_json(&d);
        let d2 = test_json_to_document(&json1);
        assert_eq!(d2.artboards.len(), 2);
        assert_eq!(d2.artboards[0].id, "aaa00001");
        assert_eq!(d2.artboards[1].name, "Cover");
        let json2 = document_to_test_json(&d2);
        assert_eq!(json1, json2);
    }

    #[test]
    fn artboard_fill_color_roundtrip() {
        let mut d = Document::default();
        d.artboards = vec![Artboard {
            id: "ccc33333".to_string(),
            name: "Red".to_string(),
            fill: ArtboardFill::Color("#ff0000".to_string()),
            ..Artboard::default_with_id("ccc33333".to_string())
        }];
        let json = document_to_test_json(&d);
        assert!(json.contains("\"fill\":\"#ff0000\""));
        let d2 = test_json_to_document(&json);
        assert_eq!(d2.artboards[0].fill, ArtboardFill::Color("#ff0000".to_string()));
    }

    #[test]
    fn artboard_options_only_emitted_when_non_default() {
        let mut d = Document::default();
        d.artboards = Vec::new();
        d.artboard_options.fade_region_outside_artboard = false;
        let json = document_to_test_json(&d);
        assert!(json.contains("\"artboard_options\""));
        assert!(json.contains("\"fade_region_outside_artboard\":false"));
    }

    #[test]
    fn artboard_options_roundtrip() {
        let mut d = Document::default();
        d.artboards = Vec::new();
        d.artboard_options = ArtboardOptions {
            fade_region_outside_artboard: false,
            update_while_dragging: false,
        };
        let json = document_to_test_json(&d);
        let d2 = test_json_to_document(&json);
        assert_eq!(d2.artboard_options.fade_region_outside_artboard, false);
        assert_eq!(d2.artboard_options.update_while_dragging, false);
    }

    #[test]
    fn legacy_fixture_without_artboards_parses_clean() {
        let legacy = r#"{"layers":[],"selected_layer":0,"selection":[]}"#;
        let d = test_json_to_document(legacy);
        assert!(d.artboards.is_empty());
        assert_eq!(d.artboard_options, ArtboardOptions::default());
        assert_eq!(d.document_setup, DocumentSetup::default());
        // Re-serializing yields the same bytes.
        let json2 = document_to_test_json(&d);
        assert_eq!(legacy, json2);
    }

    #[test]
    fn document_setup_only_emitted_when_non_default() {
        let d = Document::default();
        let json = document_to_test_json(&d);
        assert!(!json.contains("\"document_setup\""));

        let mut d2 = Document::default();
        d2.document_setup.bleed_top = 9.0;
        let json2 = document_to_test_json(&d2);
        assert!(json2.contains("\"document_setup\""));
        assert!(json2.contains("\"bleed_top\":9.0"));
    }

    #[test]
    fn document_setup_roundtrip() {
        use crate::document::print_preferences::FlattenerPreset;
        let mut d = Document::default();
        d.document_setup = DocumentSetup {
            bleed_top: 9.0,
            bleed_right: 9.0,
            bleed_bottom: 9.0,
            bleed_left: 9.0,
            bleed_uniform: false,
            show_images_outline: true,
            highlight_substituted_glyphs: true,
            grid_size: 36.0,
            grid_color: "#0099ff".to_string(),
            paper_color: "#fff8e7".to_string(),
            simulate_colored_paper: true,
            transparency_flattener_preset: FlattenerPreset::HighResolution,
            discard_white_overprint: true,
        };
        let json = document_to_test_json(&d);
        let d2 = test_json_to_document(&json);
        assert_eq!(d2.document_setup, d.document_setup);
    }

    #[test]
    fn advanced_round_trip_carries_all_choices() {
        use crate::document::print_preferences::{Advanced, FlattenerPreset};
        let mut d = Document::default();
        d.print_preferences.advanced = Advanced {
            print_as_bitmap: true,
            overprint_flattener_preset: FlattenerPreset::HighResolution,
        };
        let json = document_to_test_json(&d);
        assert!(json.contains("\"advanced\""), "json:\n{json}");
        assert!(json.contains("\"print_as_bitmap\":true"), "json:\n{json}");
        assert!(json.contains("\"overprint_flattener_preset\":\"high_resolution\""),
                "json:\n{json}");
        let d2 = test_json_to_document(&json);
        assert_eq!(d2.print_preferences.advanced, d.print_preferences.advanced);
    }

    #[test]
    fn color_management_round_trip_carries_all_choices() {
        use crate::document::print_preferences::{
            ColorHandling, ColorManagement, RenderingIntent,
        };
        let mut d = Document::default();
        d.print_preferences.color_management = ColorManagement {
            document_profile: "sRGB IEC61966-2.1".to_string(),
            color_handling: ColorHandling::PostscriptColorManagement,
            printer_profile: "U.S. Web Coated (SWOP) v2".to_string(),
            rendering_intent: RenderingIntent::Saturation,
            preserve_rgb_numbers: true,
        };
        let json = document_to_test_json(&d);
        assert!(json.contains("\"color_management\""), "json:\n{json}");
        assert!(json.contains("\"color_handling\":\"postscript_color_management\""),
                "json:\n{json}");
        assert!(json.contains("\"rendering_intent\":\"saturation\""),
                "json:\n{json}");
        assert!(json.contains("\"document_profile\":\"sRGB IEC61966-2.1\""),
                "json:\n{json}");
        let d2 = test_json_to_document(&json);
        assert_eq!(d2.print_preferences.color_management,
                   d.print_preferences.color_management);
    }

    #[test]
    fn graphics_round_trip_carries_all_choices() {
        use crate::document::print_preferences::{
            DataFormat, FontDownload, Graphics, PostScriptLevel,
        };
        let mut d = Document::default();
        d.print_preferences.graphics = Graphics {
            flatness: 0.4,
            font_download: FontDownload::Complete,
            postscript_level: PostScriptLevel::Level2,
            data_format: DataFormat::Ascii,
            compatible_gradient_printing: true,
            raster_effects_resolution: 600.0,
        };
        let json = document_to_test_json(&d);
        assert!(json.contains("\"graphics\""), "json:\n{json}");
        assert!(json.contains("\"flatness\":0.4"), "json:\n{json}");
        assert!(json.contains("\"font_download\":\"complete\""), "json:\n{json}");
        let d2 = test_json_to_document(&json);
        assert_eq!(d2.print_preferences.graphics, d.print_preferences.graphics);
    }

    #[test]
    fn output_round_trip_carries_all_inks_and_choices() {
        use crate::document::print_preferences::{
            DotShape, Emulsion, ImagePolarity, InkOverride, Output, OutputMode,
        };
        let mut d = Document::default();
        d.print_preferences.output = Output {
            mode: OutputMode::Separations,
            emulsion: Emulsion::DownRight,
            image_polarity: ImagePolarity::Negative,
            printer_resolution: "150 lpi / 1200 dpi".to_string(),
            convert_spot_to_process: true,
            overprint_black: true,
            inks: vec![
                InkOverride { name: "Process Cyan".into(),    print: false, frequency: 100.0, angle: 105.0, dot_shape: DotShape::Ellipse },
                InkOverride { name: "PANTONE 185 C".into(),   print: true,  frequency:  85.0, angle:  45.0, dot_shape: DotShape::Square },
            ],
        };
        let json = document_to_test_json(&d);
        // Output appears under print_preferences with the inks array.
        assert!(json.contains("\"output\""), "json:\n{json}");
        assert!(json.contains("\"inks\""), "json:\n{json}");
        assert!(json.contains("\"PANTONE 185 C\""), "json:\n{json}");
        let d2 = test_json_to_document(&json);
        assert_eq!(d2.print_preferences.output, d.print_preferences.output);
    }

    #[test]
    fn print_preferences_only_emitted_when_non_default() {
        let d = Document::default();
        let json = document_to_test_json(&d);
        assert!(!json.contains("\"print_preferences\""));

        let mut d2 = Document::default();
        d2.print_preferences.copies = 5;
        let json2 = document_to_test_json(&d2);
        assert!(json2.contains("\"print_preferences\""));
        assert!(json2.contains("\"copies\":5"));
    }

    #[test]
    fn print_preferences_roundtrip() {
        use crate::document::print_preferences::{
            Advanced, ArtboardRangeMode, ColorHandling, ColorManagement, DataFormat,
            DotShape, Emulsion, FlattenerPreset, FontDownload, Graphics,
            ImagePolarity, InkOverride,
            MarksAndBleed, MediaSize, Orientation, Output, OutputMode, PostScriptLevel,
            PrintLayers,
            PrinterMarkType, PrintPreferences, RenderingIntent, ScalingMode,
        };
        let mut d = Document::default();
        d.print_preferences = PrintPreferences {
            preset_name: "[Default]".to_string(),
            printer_name: Some("My Laser".to_string()),
            copies: 7,
            collate: true,
            reverse_order: true,
            artboard_range_mode: ArtboardRangeMode::Range,
            artboard_range: "1-3, 5".to_string(),
            ignore_artboards: true,
            skip_blank_artboards: true,
            media_size: MediaSize::A4,
            media_width: 595.28,
            media_height: 841.89,
            orientation: Orientation::Landscape,
            auto_rotate: false,
            transverse: true,
            print_layers: PrintLayers::All,
            placement_x: 12.0,
            placement_y: 24.0,
            scaling_mode: ScalingMode::Custom,
            custom_scale: 75.5,
            tile_overlap_h: 6.0,
            tile_overlap_v: 6.0,
            tile_range: "1-2".to_string(),
            marks_and_bleed: MarksAndBleed {
                all_printer_marks: true,
                trim_marks: true,
                registration_marks: true,
                color_bars: true,
                page_information: true,
                printer_mark_type: PrinterMarkType::Japanese,
                trim_mark_weight: 0.5,
                mark_offset: 9.0,
                use_document_bleed: false,
                bleed_top: 12.0,
                bleed_right: 18.0,
                bleed_bottom: 12.0,
                bleed_left: 18.0,
            },
            output: Output {
                mode: OutputMode::Separations,
                emulsion: Emulsion::DownRight,
                image_polarity: ImagePolarity::Negative,
                printer_resolution: "150 lpi / 1200 dpi".to_string(),
                convert_spot_to_process: true,
                overprint_black: true,
                inks: vec![
                    InkOverride { name: "Process Cyan".into(),    print: false, frequency: 100.0, angle: 105.0, dot_shape: DotShape::Ellipse },
                    InkOverride { name: "Process Magenta".into(), print: true,  frequency: 100.0, angle:  75.0, dot_shape: DotShape::Round },
                    InkOverride { name: "PANTONE 185 C".into(),   print: true,  frequency:  85.0, angle:  45.0, dot_shape: DotShape::Square },
                ],
            },
            graphics: Graphics {
                flatness: 0.4,
                font_download: FontDownload::Complete,
                postscript_level: PostScriptLevel::Level2,
                data_format: DataFormat::Ascii,
                compatible_gradient_printing: true,
                raster_effects_resolution: 600.0,
            },
            color_management: ColorManagement {
                document_profile: "sRGB IEC61966-2.1".to_string(),
                color_handling: ColorHandling::PostscriptColorManagement,
                printer_profile: "U.S. Web Coated (SWOP) v2".to_string(),
                rendering_intent: RenderingIntent::Perceptual,
                preserve_rgb_numbers: true,
            },
            advanced: Advanced {
                print_as_bitmap: true,
                overprint_flattener_preset: FlattenerPreset::LowResolution,
            },
        };
        let json = document_to_test_json(&d);
        let d2 = test_json_to_document(&json);
        assert_eq!(d2.print_preferences, d.print_preferences);
    }

    /// The shared `id`-domain corpus, driven through the real element
    /// decoder. JasSwift runs the same file in
    /// `R9CallSitePinTests.tspanIdDomainCorpusMatchesAcrossPorts`.
    #[test]
    fn tspan_id_domain_corpus() {
        let full = format!(
            "{}/../test_fixtures/{}",
            env!("CARGO_MANIFEST_DIR"),
            "algorithms/tspan_id_from_json.json"
        );
        let raw = std::fs::read_to_string(&full)
            .unwrap_or_else(|e| panic!("read {}: {}", full, e));
        let file: serde_json::Value = serde_json::from_str(&raw).expect("parse fixture");
        let vectors = file["vectors"].as_array().expect("vectors array");
        assert!(!vectors.is_empty());
        for v in vectors {
            let name = v["name"].as_str().unwrap_or("?");
            let tspans = match parse_element(&v["input"]) {
                Element::Text(t) => t.tspans,
                other => panic!("vector {}: expected a text element, got {:?}", name, other),
            };
            let expected = v["expected"].as_u64().expect("expected is a number") as u32;
            assert_eq!(tspans[0].id, expected, "vector {}", name);
            if let Some(last) = v.get("expected_last").and_then(|n| n.as_u64()) {
                assert_eq!(
                    tspans[tspans.len() - 1].id,
                    last as u32,
                    "vector {} (last tspan)",
                    name
                );
            }
        }
    }

    /// The shared canonical-JSON string-escaping corpus, driven through
    /// BOTH of this file's string writers and through the shipping element
    /// serializer. JasSwift runs the same file in
    /// `CanonicalJsonStringTests.canonicalJsonStringCorpus`.
    ///
    /// Three independent claims per vector, because before 2026-07-27 the
    /// three paths disagreed with each other:
    ///   1. `json_escape_string` itself emits the fixture's `canonical`.
    ///   2. `JsonObj::str_val` (the element/tspan/name path) emits it.
    ///   3. `canonical_value` (the recipe-params / recorded-ops path,
    ///      which used Rust's `{:?}` Debug) emits it.
    /// Plus `reparses`: the emitted bytes are valid JSON that decodes back
    /// to the input, which is the whole point of a byte oracle.
    #[test]
    fn canonical_json_string_corpus() {
        let full = format!(
            "{}/../test_fixtures/{}",
            env!("CARGO_MANIFEST_DIR"),
            "algorithms/canonical_json_string.json"
        );
        let raw = std::fs::read_to_string(&full)
            .unwrap_or_else(|e| panic!("read {}: {}", full, e));
        let file: serde_json::Value = serde_json::from_str(&raw).expect("parse fixture");
        let vectors = file["vectors"].as_array().expect("vectors array");
        assert!(!vectors.is_empty());
        for v in vectors {
            let name = v["name"].as_str().unwrap_or("?");
            let input = v["input"].as_str().expect("input is a string");
            let canonical = v["canonical"].as_str().expect("canonical is a string");

            assert_eq!(
                json_escape_string(input), canonical,
                "vector {name}: json_escape_string"
            );

            let mut o = JsonObj::new();
            o.str_val("k", input);
            assert_eq!(
                o.build(), format!("{{\"k\":{canonical}}}"),
                "vector {name}: JsonObj::str_val"
            );

            assert_eq!(
                canonical_value(&serde_json::Value::String(input.to_string())),
                canonical,
                "vector {name}: canonical_value"
            );

            if v["reparses"].as_bool().unwrap_or(false) {
                let back: serde_json::Value =
                    serde_json::from_str(&format!("{{\"k\":{canonical}}}"))
                        .unwrap_or_else(|e| panic!("vector {name}: emitted invalid JSON: {e}"));
                assert_eq!(
                    back["k"].as_str(), Some(input),
                    "vector {name}: reparse did not recover the input"
                );
            }
        }
    }

    /// The vector the ceiling blocked: a text element whose content carries
    /// a newline survives `document_to_test_json` -> `test_json_to_document`
    /// -> `document_to_test_json` unchanged. Before the escaping lift the
    /// FIRST of those calls produced a raw LF inside a JSON string, and the
    /// second panicked in serde_json.
    ///
    /// Mirrored in JasSwift by
    /// `CanonicalJsonStringTests.multiLineTextRoundTripsThroughTestJson`.
    #[test]
    fn multi_line_text_round_trips_through_test_json() {
        let content = "line one\nline two\ttabbed";
        // Built through the shipping parser so the test states no field
        // defaults of its own (TextElem has no Default impl).
        let text = parse_element(&serde_json::json!({
            "type": "text",
            "x": 10.0, "y": 20.0, "font_size": 12.0,
            "name": "a\u{7f}name",
            "tspans": [{ "id": 1, "content": content }],
        }));
        let layer = Element::Layer(LayerElem {
            children: vec![Rc::new(text)],
            isolated_blending: false,
            knockout_group: false,
            common: CommonProps::default(),
        });
        let doc = Document { layers: vec![layer], selected_layer: 0, ..Document::default() };

        let json = document_to_test_json(&doc);
        assert!(json.contains(r#""content":"line one\nline two\ttabbed""#),
                "escaped content missing from: {json}");

        let back = test_json_to_document(&json);
        match &*back.layers[0].children().unwrap()[0] {
            Element::Text(t) => {
                assert_eq!(t.tspans[0].content, content, "content did not survive");
                assert_eq!(t.common.name.as_deref(), Some("a\u{7f}name"));
            }
            other => panic!("expected Text, got {other:?}"),
        }
        // The canonical form is a fixed point, which every golden relies on.
        assert_eq!(document_to_test_json(&back), json);
    }

    // -----------------------------------------------------------------------
    // Per-call-site pins for `json_escape_string`
    //
    // `canonical_json_string_corpus` above drives the escaper through exactly
    // three entry points: the function itself, `JsonObj::str_val`, and
    // `canonical_value`'s String arm. The escaper has SIX other call sites in
    // this file, and each of them was reverted individually to its pre-2026-07-27
    // form with the whole suite green — they were routed but not gated. One test
    // per site follows, each named for its site and each reaching it through the
    // shipping serializer rather than by calling the private helper, so the pin
    // survives a refactor of the helper's signature.
    //
    // Every test uses ONE probe whose canonical spelling separates all three
    // pre-lift forms at once:
    //   probe            a " b \ c U+0008 d
    //   canonical        "a\"b\\c\bd"          (json.dumps, ensure_ascii=False)
    //   naive `"{}"`     "a"b\c<BS>d"          — invalid JSON, three ways wrong
    //   two-replacement  "a\"b\\c<BS>d"        — raw control char, still invalid
    //   Rust `{:?}`      "a\"b\\c\u{8}d"       — `\u{8}` is not a JSON escape
    // The probe deliberately contains no whitespace, because the two
    // text-decoration writers tokenize on whitespace and would swallow it.
    const ESCAPE_PROBE: &str = "a\"b\\c\u{8}d";
    /// The probe's canonical spelling, produced by
    /// `json.dumps('a"b\\c\bd', ensure_ascii=False)` — the rule's adjudicator —
    /// and NOT by running this port's escaper.
    const ESCAPE_PROBE_JSON: &str = r#""a\"b\\c\bd""#;

    /// SITE: `JsonObj::opt_str_vec` — a tspan's `text_decoration` member list.
    ///
    /// The element-wide list is held at `"none"` so it emits `[]`, which keeps
    /// this test blind to `text_decoration_json` and pins `opt_str_vec` alone.
    #[test]
    fn tspan_text_decoration_members_are_json_escaped() {
        let text = parse_element(&serde_json::json!({
            "type": "text",
            "x": 0.0, "y": 0.0, "font_size": 12.0,
            "text_decoration": "none",
            "tspans": [{
                "id": 1,
                "content": "t",
                "text_decoration": [ESCAPE_PROBE],
            }],
        }));
        let json = element_json(&text);
        assert!(
            json.contains(&format!("\"text_decoration\":[{ESCAPE_PROBE_JSON}]")),
            "tspan text_decoration member not escaped in: {json}"
        );
        // The element-wide list really is the empty one, so the assertion above
        // can only have been satisfied by the tspan writer.
        assert!(json.contains("\"text_decoration\":[]"), "in: {json}");
        // And the bytes are JSON: the whole point of the escaper.
        serde_json::from_str::<serde_json::Value>(&json).expect("emitted invalid JSON");
    }

    /// SITE: `text_decoration_json` — the element-wide `text_decoration` list.
    ///
    /// The tspan's list is left absent so it emits `null`, which keeps this test
    /// blind to `opt_str_vec` and pins `text_decoration_json` alone.
    #[test]
    fn element_text_decoration_members_are_json_escaped() {
        let text = parse_element(&serde_json::json!({
            "type": "text",
            "x": 0.0, "y": 0.0, "font_size": 12.0,
            "text_decoration": [ESCAPE_PROBE],
            "tspans": [{ "id": 1, "content": "t" }],
        }));
        let json = element_json(&text);
        assert!(
            json.contains(&format!("\"text_decoration\":[{ESCAPE_PROBE_JSON}]")),
            "element text_decoration member not escaped in: {json}"
        );
        assert!(json.contains("\"text_decoration\":null"), "tspan list not null in: {json}");
        serde_json::from_str::<serde_json::Value>(&json).expect("emitted invalid JSON");
    }

    /// SITE: `canonical_value`'s object-KEY arm — a recipe param's own key,
    /// the one key in this file that is data rather than a literal.
    ///
    /// The corpus test pins the String VALUE arm six lines above it; reverting
    /// the key arm to `{:?}` alone left the suite green.
    #[test]
    fn recipe_param_object_keys_are_json_escaped() {
        // Directly, and with a `true` value so no float formatting is involved.
        assert_eq!(
            canonical_value(&serde_json::json!({ ESCAPE_PROBE: true })),
            format!("{{{ESCAPE_PROBE_JSON}:true}}"),
        );
        // And through the shipping serializer: a recorded op's params. The op
        // name and targets are held ordinary so only the key arm can matter.
        let rec = crate::geometry::live::RecordedElem::new(
            vec![crate::document::op_log::PrimitiveOp {
                op: "translate".to_string(),
                params: serde_json::json!({ ESCAPE_PROBE: true }),
                targets: Vec::new(),
            }],
            Vec::new(),
            CommonProps::default(),
        );
        let json = element_json(&Element::Live(
            crate::geometry::live::LiveVariant::Recorded(rec),
        ));
        assert!(
            json.contains(&format!("\"params\":{{{ESCAPE_PROBE_JSON}:true}}")),
            "recipe param key not escaped in: {json}"
        );
        serde_json::from_str::<serde_json::Value>(&json).expect("emitted invalid JSON");
    }

    /// SITE: `element_json`'s Recorded arm, the `inputs` id list (was `{:?}`).
    #[test]
    fn recorded_input_ids_are_json_escaped() {
        let rec = crate::geometry::live::RecordedElem::new(
            Vec::new(),
            vec![crate::geometry::live::ElementRef(ESCAPE_PROBE.to_string())],
            CommonProps::default(),
        );
        let json = element_json(&Element::Live(
            crate::geometry::live::LiveVariant::Recorded(rec),
        ));
        assert!(
            json.contains(&format!("\"inputs\":[{ESCAPE_PROBE_JSON}]")),
            "recorded input id not escaped in: {json}"
        );
        serde_json::from_str::<serde_json::Value>(&json).expect("emitted invalid JSON");
    }

    /// SITE: `element_json`'s Recorded arm, an op's `targets` list (was `{:?}`).
    #[test]
    fn recorded_op_targets_are_json_escaped() {
        let rec = crate::geometry::live::RecordedElem::new(
            vec![crate::document::op_log::PrimitiveOp {
                op: "translate".to_string(),
                params: serde_json::json!({}),
                targets: vec![ESCAPE_PROBE.to_string()],
            }],
            Vec::new(),
            CommonProps::default(),
        );
        let json = element_json(&Element::Live(
            crate::geometry::live::LiveVariant::Recorded(rec),
        ));
        assert!(
            json.contains(&format!("\"targets\":[{ESCAPE_PROBE_JSON}]")),
            "recorded op target not escaped in: {json}"
        );
        serde_json::from_str::<serde_json::Value>(&json).expect("emitted invalid JSON");
    }

    /// SITE: `element_json`'s Recorded arm, the op NAME (was `{:?}`).
    #[test]
    fn recorded_op_name_is_json_escaped() {
        let rec = crate::geometry::live::RecordedElem::new(
            vec![crate::document::op_log::PrimitiveOp {
                op: ESCAPE_PROBE.to_string(),
                params: serde_json::json!({}),
                targets: Vec::new(),
            }],
            Vec::new(),
            CommonProps::default(),
        );
        let json = element_json(&Element::Live(
            crate::geometry::live::LiveVariant::Recorded(rec),
        ));
        assert!(
            json.contains(&format!("\"op\":{ESCAPE_PROBE_JSON}")),
            "recorded op name not escaped in: {json}"
        );
        serde_json::from_str::<serde_json::Value>(&json).expect("emitted invalid JSON");
    }
}
