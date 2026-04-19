//! Per-character-range formatting substructure of Text and TextPath.
//!
//! See `TSPAN.md` at the repository root for the full language-agnostic
//! design. This module covers the Rust side of steps B.3.1 (data model)
//! and B.3.2 (pure-function primitives). Integration with `TextElem` /
//! `TextPathElem` (making `tspans` a field on each) happens in a
//! separate step; this module is standalone so the primitives can be
//! tested against the shared algorithm vectors before that integration.

use crate::geometry::element::Transform;

/// Stable in-memory tspan identifier.
///
/// Unique within a single `Text` / `TextPath` element. Monotonic `u32`;
/// a fresh id is always strictly greater than every existing id in the
/// element. Not serialized — on SVG load, fresh ids are assigned per
/// tspan starting from 0.
pub type TspanId = u32;

/// A tspan: one contiguous character range inside a `Text` or
/// `TextPath`, carrying per-range attribute overrides.
///
/// All override fields are `None` to mean "inherit the parent
/// element's effective value". See `TSPAN.md` Attribute Inheritance.
#[derive(Debug, Clone, Default, PartialEq, serde::Serialize, serde::Deserialize)]
#[serde(default)]
pub struct Tspan {
    pub id: TspanId,
    pub content: String,
    pub baseline_shift: Option<f64>,
    pub dx: Option<f64>,
    pub font_family: Option<String>,
    pub font_size: Option<f64>,
    pub font_style: Option<String>,
    pub font_variant: Option<String>,
    pub font_weight: Option<String>,
    pub jas_aa_mode: Option<String>,
    pub jas_fractional_widths: Option<bool>,
    pub jas_kerning_mode: Option<String>,
    pub jas_no_break: Option<bool>,
    /// Marks a tspan as a paragraph wrapper when set to `Some("paragraph")`.
    /// Wrapper tspans implicitly group subsequent content tspans (until
    /// the next wrapper) into one paragraph for the Paragraph panel.
    pub jas_role: Option<String>,
    // ── Paragraph attributes (Phase 3b panel-surface subset) ────
    // Per PARAGRAPH.md §SVG attribute mapping these live on the
    // paragraph wrapper tspan (jas_role == Some("paragraph")). Phase 3b
    // adds the five panel-surface attrs that the Paragraph panel reads
    // when populating its controls; the dialog attrs (justification,
    // hyphenation params) and the remaining panel-surface space-before /
    // space-after / first-line-indent (CSS text-indent) land later.
    /// `jas:left-indent` — pt, unsigned. Effective on paragraph wrapper tspans.
    pub jas_left_indent: Option<f64>,
    /// `jas:right-indent` — pt, unsigned. Effective on paragraph wrapper tspans.
    pub jas_right_indent: Option<f64>,
    /// `jas:hyphenate` — boolean master switch on the paragraph wrapper tspan.
    pub jas_hyphenate: Option<bool>,
    /// `jas:hanging-punctuation` — boolean on the paragraph wrapper tspan.
    pub jas_hanging_punctuation: Option<bool>,
    /// `jas:list-style` — single backing attr for both BULLETS_DROPDOWN
    /// and NUMBERED_LIST_DROPDOWN. Values: bullet-disc, bullet-open-circle,
    /// bullet-square, bullet-open-square, bullet-dash, bullet-check,
    /// num-decimal, num-lower-alpha, num-upper-alpha, num-lower-roman,
    /// num-upper-roman; absent = no marker.
    pub jas_list_style: Option<String>,
    // ── Phase 1b1: remaining panel-surface paragraph attrs ──────
    /// CSS `text-align` on the paragraph wrapper tspan. Values:
    /// `left` / `center` / `right` / `justify`. Combined with
    /// `text_align_last` to drive the 7-button alignment radio group
    /// per PARAGRAPH.md alignment sub-mapping.
    pub text_align: Option<String>,
    /// CSS `text-align-last` on the paragraph wrapper tspan. Values:
    /// `left` / `center` / `right` / `justify`. Only meaningful when
    /// `text_align` is `justify` (otherwise omitted per the spec).
    pub text_align_last: Option<String>,
    /// CSS `text-indent` on the paragraph wrapper tspan — pt, signed.
    /// Negative values produce hanging indents. Backs the
    /// `FIRST_LINE_INDENT_DROPDOWN` panel control.
    pub text_indent: Option<f64>,
    /// `jas:space-before` — pt, unsigned. Vertical space above each
    /// paragraph (omitted before the first paragraph in a text element).
    pub jas_space_before: Option<f64>,
    /// `jas:space-after` — pt, unsigned. Vertical space below each
    /// paragraph.
    pub jas_space_after: Option<f64>,
    // ── Phase 1b2 / 8: Justification-dialog attrs ───────────────
    /// `jas:word-spacing-{min,desired,max}` — percent (0–1000),
    /// soft constraints fed to the every-line composer.
    pub jas_word_spacing_min: Option<f64>,
    pub jas_word_spacing_desired: Option<f64>,
    pub jas_word_spacing_max: Option<f64>,
    /// `jas:letter-spacing-{min,desired,max}` — percent (-100–500),
    /// signed soft constraints for the composer.
    pub jas_letter_spacing_min: Option<f64>,
    pub jas_letter_spacing_desired: Option<f64>,
    pub jas_letter_spacing_max: Option<f64>,
    /// `jas:glyph-scaling-{min,desired,max}` — percent (50–200),
    /// last-resort glyph-width scaling for the composer.
    pub jas_glyph_scaling_min: Option<f64>,
    pub jas_glyph_scaling_desired: Option<f64>,
    pub jas_glyph_scaling_max: Option<f64>,
    /// `jas:auto-leading` — percent of font size used when the
    /// character has Auto leading. Overrides Character's 120% default
    /// for paragraphs in the wrapping element.
    pub jas_auto_leading: Option<f64>,
    /// `jas:single-word-justify` — `justify` / `left` / `center` /
    /// `right`. How a justified line containing only one word is
    /// rendered.
    pub jas_single_word_justify: Option<String>,
    // ── Phase 1b3 / 9: Hyphenation-dialog attrs ────────────────
    /// `jas:hyphenate-min-word` — Words Longer Than N letters
    /// (range 2–25, default 3). Words shorter than this never
    /// hyphenate.
    pub jas_hyphenate_min_word: Option<f64>,
    /// `jas:hyphenate-min-before` — at least N letters appear
    /// before the hyphen (range 1–10, default 1).
    pub jas_hyphenate_min_before: Option<f64>,
    /// `jas:hyphenate-min-after` — at least N letters appear after
    /// the hyphen (range 1–10, default 1).
    pub jas_hyphenate_min_after: Option<f64>,
    /// `jas:hyphenate-limit` — max consecutive hyphen line endings
    /// (range 0–25, 0 = unlimited, default 0).
    pub jas_hyphenate_limit: Option<f64>,
    /// `jas:hyphenate-zone` — pt distance from right margin within
    /// which hyphenation is considered (non-justified paragraphs
    /// only, default 0).
    pub jas_hyphenate_zone: Option<f64>,
    /// `jas:hyphenate-bias` — discrete 7-step (0 = Better Spacing /
    /// cheap hyphens; 6 = Fewer Hyphens / expensive). Wires into
    /// the every-line composer's hyphen penalty.
    pub jas_hyphenate_bias: Option<f64>,
    /// `jas:hyphenate-capitalized` — whether to hyphenate words
    /// starting with a capital letter (default false).
    pub jas_hyphenate_capitalized: Option<bool>,
    pub letter_spacing: Option<f64>,
    pub line_height: Option<f64>,
    pub rotate: Option<f64>,
    pub style_name: Option<String>,
    /// Sorted-set of decoration members (`"underline"`, `"line-through"`).
    /// `None` inherits the parent; `Some([])` is an explicit no-decoration
    /// override; writers sort members alphabetically.
    pub text_decoration: Option<Vec<String>>,
    pub text_rendering: Option<String>,
    pub text_transform: Option<String>,
    pub transform: Option<Transform>,
    pub xml_lang: Option<String>,
}

impl Tspan {
    /// Construct a tspan with empty content, id `0`, and every override
    /// `None`. Mirrors the `tspan_default` algorithm vector.
    pub fn default_tspan() -> Self {
        Self::default()
    }

    /// Returns `true` if every override field is `None`. A tspan with no
    /// overrides is purely content — it inherits everything from its
    /// parent element.
    pub fn has_no_overrides(&self) -> bool {
        self.baseline_shift.is_none()
            && self.dx.is_none()
            && self.font_family.is_none()
            && self.font_size.is_none()
            && self.font_style.is_none()
            && self.font_variant.is_none()
            && self.font_weight.is_none()
            && self.jas_aa_mode.is_none()
            && self.jas_fractional_widths.is_none()
            && self.jas_kerning_mode.is_none()
            && self.jas_no_break.is_none()
            && self.jas_role.is_none()
            && self.jas_left_indent.is_none()
            && self.jas_right_indent.is_none()
            && self.jas_hyphenate.is_none()
            && self.jas_hanging_punctuation.is_none()
            && self.jas_list_style.is_none()
            && self.text_align.is_none()
            && self.text_align_last.is_none()
            && self.text_indent.is_none()
            && self.jas_space_before.is_none()
            && self.jas_space_after.is_none()
            && self.jas_word_spacing_min.is_none()
            && self.jas_word_spacing_desired.is_none()
            && self.jas_word_spacing_max.is_none()
            && self.jas_letter_spacing_min.is_none()
            && self.jas_letter_spacing_desired.is_none()
            && self.jas_letter_spacing_max.is_none()
            && self.jas_glyph_scaling_min.is_none()
            && self.jas_glyph_scaling_desired.is_none()
            && self.jas_glyph_scaling_max.is_none()
            && self.jas_auto_leading.is_none()
            && self.jas_single_word_justify.is_none()
            && self.jas_hyphenate_min_word.is_none()
            && self.jas_hyphenate_min_before.is_none()
            && self.jas_hyphenate_min_after.is_none()
            && self.jas_hyphenate_limit.is_none()
            && self.jas_hyphenate_zone.is_none()
            && self.jas_hyphenate_bias.is_none()
            && self.jas_hyphenate_capitalized.is_none()
            && self.letter_spacing.is_none()
            && self.line_height.is_none()
            && self.rotate.is_none()
            && self.style_name.is_none()
            && self.text_decoration.is_none()
            && self.text_rendering.is_none()
            && self.text_transform.is_none()
            && self.transform.is_none()
            && self.xml_lang.is_none()
    }
}

/// Returns the concatenation of every tspan's content in reading order.
///
/// This is the derived `Text.content` value; see `TSPAN.md` Primitives.
pub fn concat_content(tspans: &[Tspan]) -> String {
    let total_len: usize = tspans.iter().map(|t| t.content.len()).sum();
    let mut s = String::with_capacity(total_len);
    for t in tspans {
        s.push_str(&t.content);
    }
    s
}

/// Return the current index of the tspan with the given id, or `None` if
/// no such tspan exists (e.g., it was dropped by `merge`).
///
/// O(n) in tspan count. Matches `resolve_id` in `TSPAN.md`.
pub fn resolve_id(tspans: &[Tspan], id: TspanId) -> Option<usize> {
    tspans.iter().position(|t| t.id == id)
}

/// Serialize `tspans` as the rich-clipboard JSON payload described
/// in `TSPAN.md` (Cut/copy section) — a JSON object
/// `{"tspans": [...]}` with each tspan carrying its override fields
/// in snake_case. Ids are stripped (they are per-element internal
/// state); `null` override fields are omitted for compactness.
pub fn tspans_to_json_clipboard(tspans: &[Tspan]) -> String {
    let arr: Vec<serde_json::Value> = tspans.iter().map(|t| {
        let v = serde_json::to_value(t).unwrap();
        if let serde_json::Value::Object(obj) = v {
            let filtered: serde_json::Map<_, _> = obj
                .into_iter()
                .filter(|(k, v)| k != "id" && !v.is_null())
                .collect();
            serde_json::Value::Object(filtered)
        } else {
            v
        }
    }).collect();
    serde_json::to_string(&serde_json::json!({ "tspans": arr })).unwrap()
}

/// Parse a rich-clipboard JSON payload back into a tspan list. Ids
/// are assigned fresh (0, 1, 2, …) — the caller should reassign
/// above the target element's max id when splicing. Returns `None`
/// when the payload shape doesn't match.
pub fn tspans_from_json_clipboard(json_str: &str) -> Option<Vec<Tspan>> {
    let root: serde_json::Value = serde_json::from_str(json_str).ok()?;
    let arr = root.get("tspans")?.as_array()?;
    let mut out = Vec::with_capacity(arr.len());
    for (i, v) in arr.iter().enumerate() {
        let mut obj = v.as_object()?.clone();
        // Drop any accidental id, we always assign fresh.
        obj.remove("id");
        obj.insert("id".into(), serde_json::Value::from(i as u32));
        let tspan: Tspan = serde_json::from_value(serde_json::Value::Object(obj)).ok()?;
        out.push(tspan);
    }
    Some(out)
}

/// Serialize `tspans` as an SVG fragment suitable for the
/// `image/svg+xml` clipboard format. Wraps the tspans in a single
/// `<text>` element with the standard SVG namespace. See TSPAN.md.
/// Parent-element attributes (fill, font-family, etc.) are left to
/// the default since the receiver decides how to apply them.
pub fn tspans_to_svg_fragment(tspans: &[Tspan]) -> String {
    let mut out = String::new();
    out.push_str(r#"<text xmlns="http://www.w3.org/2000/svg">"#);
    for t in tspans {
        out.push_str("<tspan");
        // Writers sort attributes alphabetically for stable output.
        let mut attrs: Vec<(&str, String)> = Vec::new();
        if let Some(v) = &t.baseline_shift { attrs.push(("baseline-shift", fmt_f64(*v))); }
        if let Some(v) = &t.dx { attrs.push(("dx", fmt_f64(*v))); }
        if let Some(v) = &t.font_family { attrs.push(("font-family", v.clone())); }
        if let Some(v) = t.font_size { attrs.push(("font-size", fmt_f64(v))); }
        if let Some(v) = &t.font_style { attrs.push(("font-style", v.clone())); }
        if let Some(v) = &t.font_variant { attrs.push(("font-variant", v.clone())); }
        if let Some(v) = &t.font_weight { attrs.push(("font-weight", v.clone())); }
        if let Some(v) = &t.jas_aa_mode { attrs.push(("jas:aa-mode", v.clone())); }
        if let Some(v) = t.jas_fractional_widths { attrs.push(("jas:fractional-widths", v.to_string())); }
        if let Some(v) = &t.jas_kerning_mode { attrs.push(("jas:kerning-mode", v.clone())); }
        if let Some(v) = t.jas_no_break { attrs.push(("jas:no-break", v.to_string())); }
        if let Some(v) = &t.jas_role { attrs.push(("jas:role", v.clone())); }
        if let Some(v) = t.jas_left_indent { attrs.push(("jas:left-indent", fmt_f64(v))); }
        if let Some(v) = t.jas_right_indent { attrs.push(("jas:right-indent", fmt_f64(v))); }
        if let Some(v) = t.jas_hyphenate { attrs.push(("jas:hyphenate", v.to_string())); }
        if let Some(v) = t.jas_hanging_punctuation { attrs.push(("jas:hanging-punctuation", v.to_string())); }
        if let Some(v) = &t.jas_list_style { attrs.push(("jas:list-style", v.clone())); }
        if let Some(v) = &t.text_align { attrs.push(("text-align", v.clone())); }
        if let Some(v) = &t.text_align_last { attrs.push(("text-align-last", v.clone())); }
        if let Some(v) = t.text_indent { attrs.push(("text-indent", fmt_f64(v))); }
        if let Some(v) = t.jas_space_before { attrs.push(("jas:space-before", fmt_f64(v))); }
        if let Some(v) = t.jas_space_after { attrs.push(("jas:space-after", fmt_f64(v))); }
        if let Some(v) = t.jas_word_spacing_min { attrs.push(("jas:word-spacing-min", fmt_f64(v))); }
        if let Some(v) = t.jas_word_spacing_desired { attrs.push(("jas:word-spacing-desired", fmt_f64(v))); }
        if let Some(v) = t.jas_word_spacing_max { attrs.push(("jas:word-spacing-max", fmt_f64(v))); }
        if let Some(v) = t.jas_letter_spacing_min { attrs.push(("jas:letter-spacing-min", fmt_f64(v))); }
        if let Some(v) = t.jas_letter_spacing_desired { attrs.push(("jas:letter-spacing-desired", fmt_f64(v))); }
        if let Some(v) = t.jas_letter_spacing_max { attrs.push(("jas:letter-spacing-max", fmt_f64(v))); }
        if let Some(v) = t.jas_glyph_scaling_min { attrs.push(("jas:glyph-scaling-min", fmt_f64(v))); }
        if let Some(v) = t.jas_glyph_scaling_desired { attrs.push(("jas:glyph-scaling-desired", fmt_f64(v))); }
        if let Some(v) = t.jas_glyph_scaling_max { attrs.push(("jas:glyph-scaling-max", fmt_f64(v))); }
        if let Some(v) = t.jas_auto_leading { attrs.push(("jas:auto-leading", fmt_f64(v))); }
        if let Some(v) = &t.jas_single_word_justify { attrs.push(("jas:single-word-justify", v.clone())); }
        if let Some(v) = t.jas_hyphenate_min_word { attrs.push(("jas:hyphenate-min-word", fmt_f64(v))); }
        if let Some(v) = t.jas_hyphenate_min_before { attrs.push(("jas:hyphenate-min-before", fmt_f64(v))); }
        if let Some(v) = t.jas_hyphenate_min_after { attrs.push(("jas:hyphenate-min-after", fmt_f64(v))); }
        if let Some(v) = t.jas_hyphenate_limit { attrs.push(("jas:hyphenate-limit", fmt_f64(v))); }
        if let Some(v) = t.jas_hyphenate_zone { attrs.push(("jas:hyphenate-zone", fmt_f64(v))); }
        if let Some(v) = t.jas_hyphenate_bias { attrs.push(("jas:hyphenate-bias", fmt_f64(v))); }
        if let Some(v) = t.jas_hyphenate_capitalized { attrs.push(("jas:hyphenate-capitalized", v.to_string())); }
        if let Some(v) = t.letter_spacing { attrs.push(("letter-spacing", fmt_f64(v))); }
        if let Some(v) = t.line_height { attrs.push(("line-height", fmt_f64(v))); }
        if let Some(v) = t.rotate { attrs.push(("rotate", fmt_f64(v))); }
        if let Some(v) = &t.style_name { attrs.push(("jas:style-name", v.clone())); }
        if let Some(v) = &t.text_decoration {
            if !v.is_empty() {
                attrs.push(("text-decoration", v.join(" ")));
            }
        }
        if let Some(v) = &t.text_rendering { attrs.push(("text-rendering", v.clone())); }
        if let Some(v) = &t.text_transform { attrs.push(("text-transform", v.clone())); }
        if let Some(v) = &t.xml_lang { attrs.push(("xml:lang", v.clone())); }
        attrs.sort_by(|a, b| a.0.cmp(b.0));
        for (k, v) in attrs {
            out.push(' ');
            out.push_str(k);
            out.push_str("=\"");
            out.push_str(&xml_escape(&v));
            out.push('"');
        }
        out.push('>');
        out.push_str(&xml_escape(&t.content));
        out.push_str("</tspan>");
    }
    out.push_str("</text>");
    out
}

fn fmt_f64(v: f64) -> String {
    if v == v.trunc() { format!("{}", v as i64) } else { format!("{}", v) }
}

fn xml_escape(s: &str) -> String {
    s.replace('&', "&amp;")
        .replace('<', "&lt;")
        .replace('>', "&gt;")
        .replace('"', "&quot;")
}

/// Parse an SVG fragment that came from a `image/svg+xml` clipboard
/// payload. Expects a `<text>` root containing one or more `<tspan>`
/// children; returns their flattened tspan list (fresh ids, parse
/// errors yield `None`). Attributes map from CSS / SVG form to the
/// snake_case tspan fields.
pub fn tspans_from_svg_fragment(svg_str: &str) -> Option<Vec<Tspan>> {
    // Minimal XML tokenizer — enough for the shape our writer emits
    // and the shape other SVG apps typically produce. Handles
    // nested tspans by flattening (spec says parsers may flatten).
    let s = svg_str.trim();
    let pos = s.find("<text")?;
    let rest = &s[pos..];
    let mut out = Vec::new();
    let mut next_id: TspanId = 0;
    let mut i = 0;
    while let Some(open) = rest[i..].find("<tspan") {
        let i_open = i + open;
        let gt = rest[i_open..].find('>')?;
        let attrs_str = &rest[i_open + "<tspan".len()..i_open + gt];
        let close_tag = "</tspan>";
        let close_pos = rest[i_open + gt + 1..].find(close_tag)?;
        let content_raw = &rest[i_open + gt + 1..i_open + gt + 1 + close_pos];
        // Drop any nested <tspan>...</tspan> markup inside the
        // content; we only care about the flattened text.
        let content = xml_unescape(&strip_tags(content_raw));
        let mut t = Tspan::default_tspan();
        t.id = next_id;
        t.content = content;
        next_id += 1;
        for (k, v) in parse_xml_attrs(attrs_str) {
            match k.as_str() {
                "baseline-shift" => t.baseline_shift = v.parse().ok(),
                "dx" => t.dx = v.parse().ok(),
                "font-family" => t.font_family = Some(v),
                "font-size" => t.font_size = v.parse().ok(),
                "font-style" => t.font_style = Some(v),
                "font-variant" => t.font_variant = Some(v),
                "font-weight" => t.font_weight = Some(v),
                "jas:aa-mode" => t.jas_aa_mode = Some(v),
                "jas:fractional-widths" => t.jas_fractional_widths = Some(v == "true"),
                "jas:kerning-mode" => t.jas_kerning_mode = Some(v),
                "jas:no-break" => t.jas_no_break = Some(v == "true"),
                "jas:role" => t.jas_role = Some(v),
                "jas:left-indent" => t.jas_left_indent = v.parse().ok(),
                "jas:right-indent" => t.jas_right_indent = v.parse().ok(),
                "jas:hyphenate" => t.jas_hyphenate = Some(v == "true"),
                "jas:hanging-punctuation" => t.jas_hanging_punctuation = Some(v == "true"),
                "jas:list-style" => t.jas_list_style = Some(v),
                "text-align" => t.text_align = Some(v),
                "text-align-last" => t.text_align_last = Some(v),
                "text-indent" => t.text_indent = v.parse().ok(),
                "jas:space-before" => t.jas_space_before = v.parse().ok(),
                "jas:space-after" => t.jas_space_after = v.parse().ok(),
                "jas:word-spacing-min" => t.jas_word_spacing_min = v.parse().ok(),
                "jas:word-spacing-desired" => t.jas_word_spacing_desired = v.parse().ok(),
                "jas:word-spacing-max" => t.jas_word_spacing_max = v.parse().ok(),
                "jas:letter-spacing-min" => t.jas_letter_spacing_min = v.parse().ok(),
                "jas:letter-spacing-desired" => t.jas_letter_spacing_desired = v.parse().ok(),
                "jas:letter-spacing-max" => t.jas_letter_spacing_max = v.parse().ok(),
                "jas:glyph-scaling-min" => t.jas_glyph_scaling_min = v.parse().ok(),
                "jas:glyph-scaling-desired" => t.jas_glyph_scaling_desired = v.parse().ok(),
                "jas:glyph-scaling-max" => t.jas_glyph_scaling_max = v.parse().ok(),
                "jas:auto-leading" => t.jas_auto_leading = v.parse().ok(),
                "jas:single-word-justify" => t.jas_single_word_justify = Some(v),
                "jas:hyphenate-min-word" => t.jas_hyphenate_min_word = v.parse().ok(),
                "jas:hyphenate-min-before" => t.jas_hyphenate_min_before = v.parse().ok(),
                "jas:hyphenate-min-after" => t.jas_hyphenate_min_after = v.parse().ok(),
                "jas:hyphenate-limit" => t.jas_hyphenate_limit = v.parse().ok(),
                "jas:hyphenate-zone" => t.jas_hyphenate_zone = v.parse().ok(),
                "jas:hyphenate-bias" => t.jas_hyphenate_bias = v.parse().ok(),
                "jas:hyphenate-capitalized" => t.jas_hyphenate_capitalized = Some(v == "true"),
                "letter-spacing" => t.letter_spacing = v.parse().ok(),
                "line-height" => t.line_height = v.parse().ok(),
                "rotate" => t.rotate = v.parse().ok(),
                "jas:style-name" => t.style_name = Some(v),
                "text-decoration" => {
                    let parts: Vec<String> = v
                        .split_whitespace()
                        .filter(|p| *p != "none")
                        .map(String::from)
                        .collect();
                    t.text_decoration = Some(parts);
                }
                "text-rendering" => t.text_rendering = Some(v),
                "text-transform" => t.text_transform = Some(v),
                "xml:lang" => t.xml_lang = Some(v),
                _ => {}
            }
        }
        out.push(t);
        i = i_open + gt + 1 + close_pos + close_tag.len();
    }
    if out.is_empty() { None } else { Some(out) }
}

fn xml_unescape(s: &str) -> String {
    s.replace("&quot;", "\"")
        .replace("&gt;", ">")
        .replace("&lt;", "<")
        .replace("&amp;", "&")
}

fn strip_tags(s: &str) -> String {
    let mut out = String::with_capacity(s.len());
    let mut in_tag = false;
    for c in s.chars() {
        match c {
            '<' => in_tag = true,
            '>' if in_tag => in_tag = false,
            _ if !in_tag => out.push(c),
            _ => {}
        }
    }
    out
}

fn parse_xml_attrs(s: &str) -> Vec<(String, String)> {
    let mut out = Vec::new();
    let bytes = s.as_bytes();
    let mut i = 0;
    while i < bytes.len() {
        // Skip whitespace
        while i < bytes.len() && bytes[i].is_ascii_whitespace() { i += 1; }
        if i >= bytes.len() { break; }
        // Read name
        let name_start = i;
        while i < bytes.len() && bytes[i] != b'=' && !bytes[i].is_ascii_whitespace() { i += 1; }
        let name = std::str::from_utf8(&bytes[name_start..i]).unwrap_or("").to_string();
        if name.is_empty() { break; }
        // Skip to '='
        while i < bytes.len() && bytes[i] != b'=' { i += 1; }
        if i >= bytes.len() { break; }
        i += 1;
        // Skip to quote
        while i < bytes.len() && bytes[i] != b'"' && bytes[i] != b'\'' { i += 1; }
        if i >= bytes.len() { break; }
        let quote = bytes[i];
        i += 1;
        let val_start = i;
        while i < bytes.len() && bytes[i] != quote { i += 1; }
        let val = std::str::from_utf8(&bytes[val_start..i]).unwrap_or("").to_string();
        if i < bytes.len() { i += 1; }
        out.push((name, xml_unescape(&val)));
    }
    out
}

/// Copy every non-`None` override field from `source` into `target`.
/// Does not touch `id` or `content`. Used by the next-typed-character
/// state (the "pending override" template) when applying captured
/// overrides to newly-typed tspans.
pub fn merge_tspan_overrides(target: &mut Tspan, source: &Tspan) {
    macro_rules! copy_if_some {
        ($($f:ident),+) => { $(
            if source.$f.is_some() { target.$f = source.$f.clone(); }
        )+ };
    }
    copy_if_some!(
        baseline_shift, dx, font_family, font_size, font_style,
        font_variant, font_weight, jas_aa_mode, jas_fractional_widths,
        jas_kerning_mode, jas_no_break, jas_role,
        jas_left_indent, jas_right_indent, jas_hyphenate,
        jas_hanging_punctuation, jas_list_style,
        text_align, text_align_last, text_indent,
        jas_space_before, jas_space_after,
        jas_word_spacing_min, jas_word_spacing_desired, jas_word_spacing_max,
        jas_letter_spacing_min, jas_letter_spacing_desired, jas_letter_spacing_max,
        jas_glyph_scaling_min, jas_glyph_scaling_desired, jas_glyph_scaling_max,
        jas_auto_leading, jas_single_word_justify,
        jas_hyphenate_min_word, jas_hyphenate_min_before, jas_hyphenate_min_after,
        jas_hyphenate_limit, jas_hyphenate_zone, jas_hyphenate_bias,
        jas_hyphenate_capitalized,
        letter_spacing, line_height, rotate, style_name, text_decoration,
        text_rendering, text_transform, transform, xml_lang
    );
}

/// Caret side at a tspan boundary. See `TSPAN.md` Text-edit session
/// integration — when a character index lands exactly on the join
/// between two tspans, the affinity decides which side "wins".
///
/// `Left` corresponds to the spec's default: "new text inherits the
/// attributes of the previous character". `Right` is used by callers
/// that explicitly want the caret on the leading edge of the next
/// tspan (e.g. the user just moved the caret rightward across a
/// boundary).
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Affinity {
    Left,
    Right,
}

impl Default for Affinity {
    fn default() -> Self {
        Affinity::Left
    }
}

/// Resolve a flat character index to a concrete `(tspan_idx, offset)`
/// position given the tspan list and a caret affinity.
///
/// - Mid-tspan: returns `(i, char_idx - prefix_chars)`.
/// - Boundary between tspan `i` and `i+1`: `Left` returns the end of
///   tspan `i`; `Right` returns the start of tspan `i+1`. The very
///   last boundary (end of the final tspan) always returns the end of
///   that tspan regardless of affinity.
/// - Beyond the last tspan: clamps to the end.
/// - Empty tspan list: returns `(0, 0)`.
pub fn char_to_tspan_pos(
    tspans: &[Tspan],
    char_idx: usize,
    affinity: Affinity,
) -> (usize, usize) {
    if tspans.is_empty() {
        return (0, 0);
    }
    let mut acc = 0usize;
    for (i, t) in tspans.iter().enumerate() {
        let n = t.content.chars().count();
        if char_idx < acc + n {
            return (i, char_idx - acc);
        }
        if char_idx == acc + n {
            if i + 1 == tspans.len() {
                return (i, n);
            }
            return match affinity {
                Affinity::Left => (i, n),
                Affinity::Right => (i + 1, 0),
            };
        }
        acc += n;
    }
    let last = tspans.len() - 1;
    (last, tspans[last].content.chars().count())
}

/// Split the tspan at `tspan_idx` at character `offset`.
///
/// Returns `(new_tspans, left_idx, right_idx)`. `left_idx` and
/// `right_idx` are `None` when the side of the split is out of the list.
///
/// - `offset == 0`: no split; `left_idx = Some(tspan_idx - 1)` or `None`
///   when `tspan_idx == 0`; `right_idx = Some(tspan_idx)`.
/// - `offset == content_len`: no split; `left_idx = Some(tspan_idx)`;
///   `right_idx = Some(tspan_idx + 1)` or `None` at end of list.
/// - Otherwise: the tspan at `tspan_idx` is replaced by two tspans
///   sharing the original's attribute overrides. The left fragment keeps
///   the original's id; the right fragment receives
///   `max(existing ids) + 1` (a fresh id). Left/right indices are
///   `tspan_idx` and `tspan_idx + 1`.
///
/// Panics if `tspan_idx >= tspans.len()` or `offset > content_len`.
pub fn split(
    tspans: &[Tspan],
    tspan_idx: usize,
    offset: usize,
) -> (Vec<Tspan>, Option<usize>, Option<usize>) {
    assert!(
        tspan_idx < tspans.len(),
        "split: tspan_idx {} out of range ({} tspans)",
        tspan_idx,
        tspans.len()
    );
    let t = &tspans[tspan_idx];
    let content_len_chars = t.content.chars().count();
    assert!(
        offset <= content_len_chars,
        "split: offset {} exceeds tspan content length {}",
        offset,
        content_len_chars
    );

    if offset == 0 {
        let left = if tspan_idx > 0 { Some(tspan_idx - 1) } else { None };
        return (tspans.to_vec(), left, Some(tspan_idx));
    }
    if offset == content_len_chars {
        let right = if tspan_idx + 1 < tspans.len() {
            Some(tspan_idx + 1)
        } else {
            None
        };
        return (tspans.to_vec(), Some(tspan_idx), right);
    }

    let max_id = tspans.iter().map(|t| t.id).max().unwrap_or(0);
    let right_id = max_id + 1;

    let byte_offset: usize = t.content.chars().take(offset).map(|c| c.len_utf8()).sum();
    let mut left = t.clone();
    left.content = t.content[..byte_offset].to_string();
    let mut right = t.clone();
    right.content = t.content[byte_offset..].to_string();
    right.id = right_id;

    let mut result = Vec::with_capacity(tspans.len() + 1);
    result.extend_from_slice(&tspans[..tspan_idx]);
    result.push(left);
    result.push(right);
    result.extend_from_slice(&tspans[tspan_idx + 1..]);
    (result, Some(tspan_idx), Some(tspan_idx + 1))
}

/// Split tspans so that the character range `[char_start, char_end)` of
/// the concatenated content is covered exactly by a contiguous run of
/// tspans. Returns `(new_tspans, first_idx, last_idx)` with the
/// first/last indices inclusive, both `None` when the range is empty.
///
/// Panics if `char_start > char_end` or `char_end` exceeds the total
/// content length.
pub fn split_range(
    tspans: &[Tspan],
    char_start: usize,
    char_end: usize,
) -> (Vec<Tspan>, Option<usize>, Option<usize>) {
    assert!(
        char_start <= char_end,
        "split_range: char_start {} > char_end {}",
        char_start,
        char_end
    );
    let total: usize = tspans.iter().map(|t| t.content.chars().count()).sum();
    assert!(
        char_end <= total,
        "split_range: char_end {} exceeds content length {}",
        char_end,
        total
    );

    if char_start == char_end {
        return (tspans.to_vec(), None, None);
    }

    let mut next_id: TspanId = tspans
        .iter()
        .map(|t| t.id)
        .max()
        .map(|m| m + 1)
        .unwrap_or(0);
    let mut result: Vec<Tspan> = Vec::with_capacity(tspans.len() + 2);
    let mut first_idx: Option<usize> = None;
    let mut last_idx: Option<usize> = None;
    let mut cursor = 0usize;

    for t in tspans {
        let len = t.content.chars().count();
        let tspan_start = cursor;
        let tspan_end = cursor + len;
        let overlap_start = char_start.max(tspan_start);
        let overlap_end = char_end.min(tspan_end);

        if overlap_start >= overlap_end {
            result.push(t.clone());
        } else {
            let local_start = overlap_start - tspan_start;
            let local_end = overlap_end - tspan_start;
            let byte_start: usize = t
                .content
                .chars()
                .take(local_start)
                .map(|c| c.len_utf8())
                .sum();
            let byte_end: usize = t
                .content
                .chars()
                .take(local_end)
                .map(|c| c.len_utf8())
                .sum();

            if local_start > 0 {
                let mut prefix = t.clone();
                prefix.content = t.content[..byte_start].to_string();
                // prefix keeps the original id
                result.push(prefix);
            }

            let mut middle = t.clone();
            middle.content = t.content[byte_start..byte_end].to_string();
            if local_start > 0 {
                // middle is the right side of the char_start split → fresh id
                middle.id = next_id;
                next_id += 1;
            }
            let middle_idx = result.len();
            if first_idx.is_none() {
                first_idx = Some(middle_idx);
            }
            last_idx = Some(middle_idx);
            result.push(middle);

            if local_end < len {
                let mut suffix = t.clone();
                suffix.content = t.content[byte_end..].to_string();
                // suffix is the right side of the char_end split → fresh id
                suffix.id = next_id;
                next_id += 1;
                result.push(suffix);
            }
        }

        cursor = tspan_end;
    }

    (result, first_idx, last_idx)
}

/// Merge adjacent tspans with identical resolved override sets, drop
/// empty-content tspans unconditionally. Preserves the "at least one
/// tspan" invariant: if every tspan would collapse to empty, returns a
/// single default tspan.
///
/// The surviving (left) tspan keeps its id; the right tspan's id is
/// dropped.
pub fn merge(tspans: &[Tspan]) -> Vec<Tspan> {
    let filtered: Vec<&Tspan> = tspans.iter().filter(|t| !t.content.is_empty()).collect();
    if filtered.is_empty() {
        return vec![Tspan::default_tspan()];
    }

    let mut result: Vec<Tspan> = Vec::with_capacity(filtered.len());
    for t in filtered {
        match result.last_mut() {
            Some(prev) if attrs_equal(prev, t) => {
                prev.content.push_str(&t.content);
            }
            _ => {
                result.push(t.clone());
            }
        }
    }
    result
}

/// Returns `true` when the two tspans share identical override sets
/// (every optional field equal). Content and id are ignored.
fn attrs_equal(a: &Tspan, b: &Tspan) -> bool {
    a.baseline_shift == b.baseline_shift
        && a.dx == b.dx
        && a.font_family == b.font_family
        && a.font_size == b.font_size
        && a.font_style == b.font_style
        && a.font_variant == b.font_variant
        && a.font_weight == b.font_weight
        && a.jas_aa_mode == b.jas_aa_mode
        && a.jas_fractional_widths == b.jas_fractional_widths
        && a.jas_kerning_mode == b.jas_kerning_mode
        && a.jas_no_break == b.jas_no_break
        && a.letter_spacing == b.letter_spacing
        && a.line_height == b.line_height
        && a.rotate == b.rotate
        && a.style_name == b.style_name
        && a.text_decoration == b.text_decoration
        && a.text_rendering == b.text_rendering
        && a.text_transform == b.text_transform
        && a.transform == b.transform
        && a.xml_lang == b.xml_lang
}

/// Extract the covered slice `[char_start, char_end)` of the input
/// as a fresh tspan list. Each returned tspan carries its source
/// tspan's overrides and id, with `content` truncated to the
/// overlap. Empty range → empty Vec. Out-of-range bounds saturate.
///
/// Building block for tspan-aware clipboard: `copy_range` produces
/// the tspan payload to stash, and `insert_tspans_at` consumes it
/// at paste time.
pub fn copy_range(original: &[Tspan], char_start: usize, char_end: usize) -> Vec<Tspan> {
    if char_start >= char_end {
        return Vec::new();
    }
    let total: usize = original.iter().map(|t| t.content.chars().count()).sum();
    let start = char_start.min(total);
    let end = char_end.min(total);
    if start >= end {
        return Vec::new();
    }

    let mut result = Vec::new();
    let mut cursor = 0usize;
    for t in original {
        let t_len = t.content.chars().count();
        let t_start = cursor;
        let t_end = cursor + t_len;
        let overlap_start = start.max(t_start);
        let overlap_end = end.min(t_end);
        if overlap_start < overlap_end {
            let local_start = overlap_start - t_start;
            let local_end = overlap_end - t_start;
            let byte_start: usize = t.content.chars().take(local_start).map(|c| c.len_utf8()).sum();
            let byte_end: usize = t.content.chars().take(local_end).map(|c| c.len_utf8()).sum();
            let mut cloned = t.clone();
            cloned.content = t.content[byte_start..byte_end].to_string();
            result.push(cloned);
        }
        cursor = t_end;
    }
    result
}

/// Splice `to_insert` into `original` at character position
/// `char_pos`. When `char_pos` lands inside a tspan, that tspan
/// splits around the insertion; when at a boundary, the new tspans
/// slot between neighbours cleanly. Ids on `to_insert` are
/// reassigned to avoid collision with `original`'s ids, so the
/// caller can reuse tspans copied from the same or a different
/// element without worrying about id clashes.
///
/// Runs the final `merge` pass so adjacent tspans whose overrides
/// match collapse automatically.
pub fn insert_tspans_at(
    original: &[Tspan],
    char_pos: usize,
    to_insert: &[Tspan],
) -> Vec<Tspan> {
    // Empty insertion: no-op. Empty-content-only tspans drop out
    // via merge, so treat them as empty too.
    let nonempty = to_insert.iter().any(|t| !t.content.is_empty());
    if !nonempty {
        return original.to_vec();
    }

    // Re-id to_insert to sit above original's max id.
    let base_max = original.iter().map(|t| t.id).max().unwrap_or(0);
    let mut next_id = base_max + 1;
    let reindexed: Vec<Tspan> = to_insert.iter().map(|t| {
        let mut cloned = t.clone();
        cloned.id = next_id;
        next_id += 1;
        cloned
    }).collect();

    // Split original at char_pos into left / right halves.
    let total: usize = original.iter().map(|t| t.content.chars().count()).sum();
    let pos = char_pos.min(total);
    let mut before: Vec<Tspan> = Vec::new();
    let mut after: Vec<Tspan> = Vec::new();
    let mut cursor = 0usize;
    for t in original {
        let t_len = t.content.chars().count();
        let t_end = cursor + t_len;
        if t_end <= pos {
            before.push(t.clone());
        } else if cursor >= pos {
            after.push(t.clone());
        } else {
            let local = pos - cursor;
            let byte: usize = t.content.chars().take(local).map(|c| c.len_utf8()).sum();
            let mut left = t.clone();
            left.content = t.content[..byte].to_string();
            before.push(left);
            // Right half gets a fresh id (max + inserted + 1) to
            // avoid colliding with the left half that keeps the
            // original id.
            let mut right = t.clone();
            right.id = next_id;
            next_id += 1;
            right.content = t.content[byte..].to_string();
            after.push(right);
        }
        cursor = t_end;
    }

    let mut result: Vec<Tspan> =
        Vec::with_capacity(before.len() + reindexed.len() + after.len());
    result.extend(before);
    result.extend(reindexed);
    result.extend(after);
    merge(&result)
}

/// Reconcile a new flat content string back onto the original tspan
/// structure, preserving per-range attribute overrides where possible.
///
/// The unchanged common prefix and suffix (measured in bytes, snapped
/// to UTF-8 char boundaries) keep their original tspan assignments.
/// The changed middle region is absorbed into the first tspan that
/// overlaps it — extending that tspan's content — with subsequent
/// overlapping tspans truncated to their post-middle suffix. The
/// result is passed through `merge` to drop empty tspans and combine
/// adjacent ones whose override sets now match.
///
/// Used by the text-edit session commit path: if the user's edits
/// didn't touch a stretch of text that lived in a bold tspan, that
/// tspan's bold override survives. Any edit that fully replaces a
/// tspan's content collapses its overrides into the neighbour that
/// absorbed the change.
pub fn reconcile_content(original: &[Tspan], new_content: &str) -> Vec<Tspan> {
    let old_content = concat_content(original);
    if old_content == new_content {
        return original.to_vec();
    }
    if original.is_empty() {
        let mut t = Tspan::default_tspan();
        t.content = new_content.to_string();
        return vec![t];
    }

    let old_bytes = old_content.as_bytes();
    let new_bytes = new_content.as_bytes();

    // Longest common prefix (byte-level), snapped to a UTF-8 boundary.
    let max_prefix = old_bytes.len().min(new_bytes.len());
    let mut prefix_len = 0;
    while prefix_len < max_prefix && old_bytes[prefix_len] == new_bytes[prefix_len] {
        prefix_len += 1;
    }
    while prefix_len > 0 && !old_content.is_char_boundary(prefix_len) {
        prefix_len -= 1;
    }

    // Longest common suffix, bounded so it doesn't overlap the prefix.
    let max_suffix = (old_bytes.len() - prefix_len).min(new_bytes.len() - prefix_len);
    let mut suffix_len = 0;
    while suffix_len < max_suffix
        && old_bytes[old_bytes.len() - 1 - suffix_len]
            == new_bytes[new_bytes.len() - 1 - suffix_len]
    {
        suffix_len += 1;
    }
    while suffix_len > 0
        && !old_content.is_char_boundary(old_bytes.len() - suffix_len)
    {
        suffix_len -= 1;
    }

    // Changed region in bytes: old[prefix..old_len-suffix), new[prefix..new_len-suffix).
    let old_mid_start = prefix_len;
    let old_mid_end = old_bytes.len() - suffix_len;
    let new_middle = &new_content[prefix_len..new_bytes.len() - suffix_len];

    // Pure insertion at a boundary (old middle is empty): find the
    // tspan containing old_mid_start and splice new_middle into its
    // content. Keeps all override assignments intact.
    if old_mid_start == old_mid_end {
        let mut result = original.to_vec();
        let mut pos = old_mid_start;
        let mut absorbed = false;
        for tspan in result.iter_mut() {
            let t_len = tspan.content.len();
            if pos <= t_len {
                let mut s = String::with_capacity(t_len + new_middle.len());
                s.push_str(&tspan.content[..pos]);
                s.push_str(new_middle);
                s.push_str(&tspan.content[pos..]);
                tspan.content = s;
                absorbed = true;
                break;
            }
            pos -= t_len;
        }
        if !absorbed {
            if let Some(last) = result.last_mut() {
                last.content.push_str(new_middle);
            } else {
                let mut t = Tspan::default_tspan();
                t.content = new_middle.to_string();
                result.push(t);
            }
        }
        return merge(&result);
    }

    // Replacement (including pure deletion): walk tspans and absorb
    // new_middle into the first tspan that overlaps the changed
    // region. Tspans fully before / after pass through; a tspan
    // fully inside the middle ends up with empty content and is
    // dropped by the subsequent merge pass.
    let mut result: Vec<Tspan> = Vec::with_capacity(original.len() + 1);
    let mut cursor_bytes = 0usize;
    let mut middle_consumed = false;

    for tspan in original {
        let t_start = cursor_bytes;
        let t_end = cursor_bytes + tspan.content.len();

        if t_end <= old_mid_start {
            result.push(tspan.clone());
        } else if t_start >= old_mid_end {
            result.push(tspan.clone());
        } else {
            let before_len = old_mid_start.saturating_sub(t_start);
            let after_off_in_tspan = if t_end > old_mid_end {
                old_mid_end - t_start
            } else {
                tspan.content.len()
            };
            let before = &tspan.content[..before_len];
            let after = if t_end > old_mid_end {
                &tspan.content[after_off_in_tspan..]
            } else {
                ""
            };

            let mut new_tspan_content =
                String::with_capacity(before.len() + after.len() + new_middle.len());
            new_tspan_content.push_str(before);
            if !middle_consumed {
                new_tspan_content.push_str(new_middle);
                middle_consumed = true;
            }
            new_tspan_content.push_str(after);

            if !new_tspan_content.is_empty() {
                let mut new_tspan = tspan.clone();
                new_tspan.content = new_tspan_content;
                result.push(new_tspan);
            }
        }
        cursor_bytes = t_end;
    }

    if result.is_empty() {
        result.push(Tspan::default_tspan());
    }

    merge(&result)
}

#[cfg(test)]
mod tests {
    use super::*;

    // Absolute path to the shared test-fixture root.
    const FIXTURES: &str = concat!(env!("CARGO_MANIFEST_DIR"), "/../test_fixtures");

    fn load(path: &str) -> serde_json::Value {
        let full = format!("{}/{}", FIXTURES, path);
        let raw = std::fs::read_to_string(&full)
            .unwrap_or_else(|e| panic!("read {}: {}", full, e));
        serde_json::from_str(&raw).unwrap_or_else(|e| panic!("parse {}: {}", full, e))
    }

    fn parse_tspans(v: &serde_json::Value) -> Vec<Tspan> {
        serde_json::from_value(v.clone()).expect("parse tspan list")
    }

    fn opt_usize(v: &serde_json::Value) -> Option<usize> {
        v.as_u64().map(|n| n as usize)
    }

    // ── default_tspan ───────────────────────────────────────────────

    #[test]
    fn default_tspan_returns_empty_with_id_zero() {
        let file = load("algorithms/tspan_default.json");
        let vectors = file["vectors"].as_array().unwrap();
        for v in vectors {
            let expected: Tspan = serde_json::from_value(v["expected"].clone()).unwrap();
            let got = Tspan::default_tspan();
            assert_eq!(got, expected, "vector {}", v["name"]);
            assert_eq!(got.id, 0);
            assert!(got.content.is_empty());
            assert!(got.has_no_overrides());
        }
    }

    // ── concat_content ──────────────────────────────────────────────

    #[test]
    fn concat_content_matches_fixtures() {
        let file = load("algorithms/tspan_concat_content.json");
        let vectors = file["vectors"].as_array().unwrap();
        for v in vectors {
            let tspans = parse_tspans(&v["tspans"]);
            let expected = v["expected"].as_str().unwrap();
            assert_eq!(concat_content(&tspans), expected, "vector {}", v["name"]);
        }
    }

    // ── split ───────────────────────────────────────────────────────

    #[test]
    fn split_matches_fixtures() {
        let file = load("algorithms/tspan_split.json");
        let vectors = file["vectors"].as_array().unwrap();
        for v in vectors {
            let input = &v["input"];
            let tspans = parse_tspans(&input["tspans"]);
            let idx = input["tspan_idx"].as_u64().unwrap() as usize;
            let offset = input["offset"].as_u64().unwrap() as usize;

            let (got, got_left, got_right) = split(&tspans, idx, offset);

            let expected = &v["expected"];
            let expected_tspans = parse_tspans(&expected["tspans"]);
            let expected_left = opt_usize(&expected["left_idx"]);
            let expected_right = opt_usize(&expected["right_idx"]);

            assert_eq!(got, expected_tspans, "vector {} tspans", v["name"]);
            assert_eq!(got_left, expected_left, "vector {} left_idx", v["name"]);
            assert_eq!(got_right, expected_right, "vector {} right_idx", v["name"]);
        }
    }

    // ── split_range ─────────────────────────────────────────────────

    #[test]
    fn split_range_matches_fixtures() {
        let file = load("algorithms/tspan_split_range.json");
        let vectors = file["vectors"].as_array().unwrap();
        for v in vectors {
            let input = &v["input"];
            let tspans = parse_tspans(&input["tspans"]);
            let start = input["char_start"].as_u64().unwrap() as usize;
            let end = input["char_end"].as_u64().unwrap() as usize;

            let (got, got_first, got_last) = split_range(&tspans, start, end);

            let expected = &v["expected"];
            let expected_tspans = parse_tspans(&expected["tspans"]);
            let expected_first = opt_usize(&expected["first_idx"]);
            let expected_last = opt_usize(&expected["last_idx"]);

            assert_eq!(got, expected_tspans, "vector {} tspans", v["name"]);
            assert_eq!(got_first, expected_first, "vector {} first_idx", v["name"]);
            assert_eq!(got_last, expected_last, "vector {} last_idx", v["name"]);
        }
    }

    // ── merge ───────────────────────────────────────────────────────

    #[test]
    fn merge_matches_fixtures() {
        let file = load("algorithms/tspan_merge.json");
        let vectors = file["vectors"].as_array().unwrap();
        for v in vectors {
            let input_tspans = parse_tspans(&v["input"]["tspans"]);
            let expected_tspans = parse_tspans(&v["expected"]["tspans"]);
            let got = merge(&input_tspans);
            assert_eq!(got, expected_tspans, "vector {}", v["name"]);
        }
    }

    // ── resolve_id ──────────────────────────────────────────────────

    #[test]
    fn resolve_id_matches_fixtures() {
        let file = load("algorithms/tspan_resolve_id.json");
        let vectors = file["vectors"].as_array().unwrap();
        for v in vectors {
            let input = &v["input"];
            let tspans = parse_tspans(&input["tspans"]);
            let id = input["id"].as_u64().unwrap() as TspanId;

            let got = resolve_id(&tspans, id);
            let expected = opt_usize(&v["expected"]);

            assert_eq!(got, expected, "vector {}", v["name"]);
        }
    }

    // ── Hand-written sanity tests that don't depend on fixtures ─────

    #[test]
    fn split_preserves_attribute_overrides_on_both_sides() {
        let original = Tspan {
            id: 0,
            content: "Hello".to_string(),
            font_weight: Some("bold".to_string()),
            ..Tspan::default_tspan()
        };
        let (got, _left, _right) = split(&[original.clone()], 0, 2);
        assert_eq!(got.len(), 2);
        assert_eq!(got[0].font_weight.as_deref(), Some("bold"));
        assert_eq!(got[1].font_weight.as_deref(), Some("bold"));
        assert_eq!(got[0].content, "He");
        assert_eq!(got[1].content, "llo");
        assert_eq!(got[0].id, 0);
        assert_eq!(got[1].id, 1);
    }

    #[test]
    fn merge_preserves_attribute_overrides() {
        let a = Tspan {
            id: 0,
            content: "A".to_string(),
            font_weight: Some("bold".to_string()),
            ..Tspan::default_tspan()
        };
        let b = Tspan {
            id: 1,
            content: "B".to_string(),
            font_weight: Some("bold".to_string()),
            ..Tspan::default_tspan()
        };
        let got = merge(&[a, b]);
        assert_eq!(got.len(), 1);
        assert_eq!(got[0].content, "AB");
        assert_eq!(got[0].font_weight.as_deref(), Some("bold"));
        assert_eq!(got[0].id, 0);
    }

    #[test]
    fn merge_does_not_combine_different_overrides() {
        let a = Tspan {
            id: 0,
            content: "A".to_string(),
            font_weight: Some("bold".to_string()),
            ..Tspan::default_tspan()
        };
        let b = Tspan {
            id: 1,
            content: "B".to_string(),
            font_weight: Some("normal".to_string()),
            ..Tspan::default_tspan()
        };
        let got = merge(&[a, b]);
        assert_eq!(got.len(), 2);
    }

    #[test]
    fn resolve_id_after_merge_loses_right_id() {
        let a = Tspan {
            id: 0,
            content: "A".to_string(),
            ..Tspan::default_tspan()
        };
        let b = Tspan {
            id: 3,
            content: "B".to_string(),
            ..Tspan::default_tspan()
        };
        let merged = merge(&[a, b]);
        assert_eq!(resolve_id(&merged, 0), Some(0));
        assert_eq!(resolve_id(&merged, 3), None);
    }

    // ── reconcile_content ──────────────────────────────────────

    fn bold(s: &str) -> Tspan {
        Tspan {
            content: s.to_string(),
            font_weight: Some("bold".into()),
            ..Tspan::default_tspan()
        }
    }
    fn plain(s: &str) -> Tspan {
        Tspan { content: s.to_string(), ..Tspan::default_tspan() }
    }

    #[test]
    fn reconcile_identity_passes_through() {
        let tspans = vec![plain("Hello "), bold("world")];
        let r = reconcile_content(&tspans, "Hello world");
        assert_eq!(r, tspans);
    }

    #[test]
    fn reconcile_append_extends_last_tspan() {
        // "Hello world" → "Hello world!": '!' is pure suffix append.
        // The trailing bold "world" absorbs the new '!'.
        let tspans = vec![plain("Hello "), bold("world")];
        let r = reconcile_content(&tspans, "Hello world!");
        assert_eq!(r.len(), 2);
        assert_eq!(r[0].content, "Hello ");
        assert_eq!(r[1].content, "world!");
        assert_eq!(r[1].font_weight.as_deref(), Some("bold"));
    }

    #[test]
    fn reconcile_prepend_extends_first_tspan() {
        let tspans = vec![plain("Hello "), bold("world")];
        let r = reconcile_content(&tspans, "Say Hello world");
        assert_eq!(r.len(), 2);
        assert_eq!(r[0].content, "Say Hello ");
        assert_eq!(r[1].content, "world");
        assert_eq!(r[1].font_weight.as_deref(), Some("bold"));
    }

    #[test]
    fn reconcile_edit_inside_a_tspan_preserves_neighbours() {
        // "Hello world" → "Hellooo world": insert "oo" inside the
        // plain tspan. Bold "world" preserved untouched.
        let tspans = vec![plain("Hello "), bold("world")];
        let r = reconcile_content(&tspans, "Hellooo world");
        assert_eq!(r.len(), 2);
        assert_eq!(r[0].content, "Hellooo ");
        assert!(r[0].font_weight.is_none());
        assert_eq!(r[1].content, "world");
        assert_eq!(r[1].font_weight.as_deref(), Some("bold"));
    }

    #[test]
    fn reconcile_delete_inside_a_tspan() {
        // "Hello world" → "Helo world": drop one 'l' from the plain tspan.
        let tspans = vec![plain("Hello "), bold("world")];
        let r = reconcile_content(&tspans, "Helo world");
        assert_eq!(r.len(), 2);
        assert_eq!(r[0].content, "Helo ");
        assert_eq!(r[1].content, "world");
        assert_eq!(r[1].font_weight.as_deref(), Some("bold"));
    }

    #[test]
    fn reconcile_change_absorbs_into_first_overlapping_tspan() {
        // "Hello world" → "HelloXXworld": the middle " " vanishes,
        // "XX" inserted, touching both tspans. First overlapping
        // (plain "Hello ") absorbs the change.
        let tspans = vec![plain("Hello "), bold("world")];
        let r = reconcile_content(&tspans, "HelloXXworld");
        assert_eq!(r.len(), 2);
        assert_eq!(r[0].content, "HelloXX");
        assert!(r[0].font_weight.is_none());
        assert_eq!(r[1].content, "world");
        assert_eq!(r[1].font_weight.as_deref(), Some("bold"));
    }

    #[test]
    fn reconcile_delete_all_yields_single_default_tspan() {
        let tspans = vec![plain("Hello "), bold("world")];
        let r = reconcile_content(&tspans, "");
        assert_eq!(r.len(), 1);
        assert!(r[0].content.is_empty());
        assert!(r[0].has_no_overrides());
    }

    #[test]
    fn reconcile_full_replacement_collapses_to_single_tspan() {
        // Every char changes → no common prefix / suffix. Middle is
        // the whole new content, absorbed into the first tspan.
        let tspans = vec![plain("abc"), bold("def")];
        let r = reconcile_content(&tspans, "xyz");
        // After merge: one tspan with "xyz" (plus plain's override set).
        assert_eq!(r.len(), 1);
        assert_eq!(r[0].content, "xyz");
    }

    #[test]
    fn reconcile_preserves_utf8_boundaries() {
        // Multibyte chars on each side of the edit: the back-off
        // logic must not split a codepoint.
        let tspans = vec![plain("café "), bold("naïve")];
        let r = reconcile_content(&tspans, "café plus naïve");
        assert_eq!(r.len(), 2);
        assert_eq!(r[0].content, "café plus ");
        assert_eq!(r[1].content, "naïve");
        assert_eq!(r[1].font_weight.as_deref(), Some("bold"));
    }

    #[test]
    fn reconcile_runs_merge_cleanup() {
        // After editing, adjacent tspans with matching overrides
        // collapse via the merge primitive.
        let tspans = vec![plain("a"), plain("b"), bold("C")];
        // Remove the 'C' → merge should collapse "a"+"b" into one tspan.
        let r = reconcile_content(&tspans, "ab");
        assert_eq!(r.len(), 1);
        assert_eq!(r[0].content, "ab");
    }

    // ── copy_range ──────────────────────────────────────────────

    #[test]
    fn copy_range_empty_returns_empty() {
        let tspans = vec![plain("hello")];
        assert!(copy_range(&tspans, 2, 2).is_empty());
        assert!(copy_range(&tspans, 3, 1).is_empty());
    }

    #[test]
    fn copy_range_inside_single_tspan_preserves_overrides() {
        let tspans = vec![bold("bold text")];
        let r = copy_range(&tspans, 5, 9);
        assert_eq!(r.len(), 1);
        assert_eq!(r[0].content, "text");
        assert_eq!(r[0].font_weight.as_deref(), Some("bold"));
    }

    #[test]
    fn copy_range_across_boundary_returns_both_partial_tspans() {
        // "foo" + bold "bar": copy chars 1..5 → "oo" + "ba"
        let tspans = vec![plain("foo"), bold("bar")];
        let r = copy_range(&tspans, 1, 5);
        assert_eq!(r.len(), 2);
        assert_eq!(r[0].content, "oo");
        assert!(r[0].font_weight.is_none());
        assert_eq!(r[1].content, "ba");
        assert_eq!(r[1].font_weight.as_deref(), Some("bold"));
    }

    #[test]
    fn copy_range_end_saturates_to_total() {
        let tspans = vec![plain("hi")];
        let r = copy_range(&tspans, 0, 999);
        assert_eq!(r.len(), 1);
        assert_eq!(r[0].content, "hi");
    }

    // ── insert_tspans_at ────────────────────────────────────────

    #[test]
    fn insert_tspans_at_boundary_between_tspans() {
        // "foo" + bold "bar"; insert bold "X" at char_pos=3 (boundary).
        let base = vec![plain("foo"), bold("bar")];
        let ins = vec![bold("X")];
        let r = insert_tspans_at(&base, 3, &ins);
        // Expect: foo | bold X | bold bar → merge collapses boldX+boldbar
        assert_eq!(r.len(), 2);
        assert_eq!(r[0].content, "foo");
        assert_eq!(r[1].content, "Xbar");
        assert_eq!(r[1].font_weight.as_deref(), Some("bold"));
    }

    #[test]
    fn insert_tspans_at_inside_a_tspan_splits() {
        // Plain "hello"; insert bold "X" at char_pos=2.
        let base = vec![plain("hello")];
        let ins = vec![bold("X")];
        let r = insert_tspans_at(&base, 2, &ins);
        // Expect: plain "he" | bold "X" | plain "llo"
        assert_eq!(r.len(), 3);
        assert_eq!(r[0].content, "he");
        assert!(r[0].font_weight.is_none());
        assert_eq!(r[1].content, "X");
        assert_eq!(r[1].font_weight.as_deref(), Some("bold"));
        assert_eq!(r[2].content, "llo");
        assert!(r[2].font_weight.is_none());
    }

    #[test]
    fn insert_tspans_at_prepend_at_position_zero() {
        let base = vec![plain("hello")];
        let ins = vec![bold("Say ")];
        let r = insert_tspans_at(&base, 0, &ins);
        assert_eq!(r.len(), 2);
        assert_eq!(r[0].content, "Say ");
        assert_eq!(r[0].font_weight.as_deref(), Some("bold"));
        assert_eq!(r[1].content, "hello");
    }

    #[test]
    fn insert_tspans_at_append_at_end() {
        let base = vec![plain("hello")];
        let ins = vec![bold("!")];
        let r = insert_tspans_at(&base, 5, &ins);
        assert_eq!(r.len(), 2);
        assert_eq!(r[0].content, "hello");
        assert_eq!(r[1].content, "!");
        assert_eq!(r[1].font_weight.as_deref(), Some("bold"));
    }

    #[test]
    fn insert_tspans_at_reassigns_ids() {
        let base = vec![Tspan { id: 0, content: "abc".into(), ..Tspan::default_tspan() }];
        let ins = vec![
            Tspan { id: 0, content: "X".into(), font_weight: Some("bold".into()),
                    ..Tspan::default_tspan() },
        ];
        let r = insert_tspans_at(&base, 1, &ins);
        // All ids must be distinct.
        let mut ids: Vec<u32> = r.iter().map(|t| t.id).collect();
        ids.sort();
        ids.dedup();
        assert_eq!(ids.len(), r.len());
    }

    #[test]
    fn insert_empty_is_noop() {
        let base = vec![plain("hello")];
        assert_eq!(insert_tspans_at(&base, 2, &[]), base);
        assert_eq!(insert_tspans_at(&base, 2, &[plain("")]), base);
    }

    #[test]
    fn copy_then_insert_roundtrip_preserves_overrides() {
        // "foo" + bold "bar": copy "bar", paste at 0 → bold "bar" + "foo" + bold "bar"
        let base = vec![plain("foo"), bold("bar")];
        let clipboard = copy_range(&base, 3, 6);
        let r = insert_tspans_at(&base, 0, &clipboard);
        assert_eq!(concat_content(&r), "barfoobar");
        // Original bold "bar" preserved; new prefix "bar" also bold via clipboard.
        assert!(r.iter().any(|t| t.content.contains("bar") && t.font_weight.as_deref() == Some("bold")));
    }

    // ── rich clipboard: JSON + SVG formats ─────────────────────────

    #[test]
    fn json_clipboard_roundtrip_preserves_content_and_overrides() {
        let src = vec![
            plain("foo"),
            bold("bar"),
        ];
        let json = tspans_to_json_clipboard(&src);
        let back = tspans_from_json_clipboard(&json).expect("parse");
        assert_eq!(back.len(), 2);
        assert_eq!(back[0].content, "foo");
        assert!(back[0].font_weight.is_none());
        assert_eq!(back[1].content, "bar");
        assert_eq!(back[1].font_weight.as_deref(), Some("bold"));
    }

    #[test]
    fn json_clipboard_strips_id() {
        let src = vec![Tspan { id: 42, content: "x".into(),
                               ..Tspan::default_tspan() }];
        let json = tspans_to_json_clipboard(&src);
        // Payload must not leak the source id.
        assert!(!json.contains("\"id\":42"));
        assert!(!json.contains("\"id\": 42"));
    }

    #[test]
    fn json_clipboard_strips_null_overrides() {
        let src = vec![plain("foo")];
        let json = tspans_to_json_clipboard(&src);
        // None fields should be absent from the JSON body, not ": null".
        assert!(!json.contains("null"));
    }

    #[test]
    fn json_clipboard_from_assigns_fresh_ids() {
        let json = r#"{"tspans":[{"content":"a"},{"content":"b"}]}"#;
        let back = tspans_from_json_clipboard(json).unwrap();
        assert_eq!(back.len(), 2);
        assert_eq!(back[0].id, 0);
        assert_eq!(back[1].id, 1);
    }

    #[test]
    fn json_clipboard_from_rejects_bad_payload() {
        assert!(tspans_from_json_clipboard("not json").is_none());
        assert!(tspans_from_json_clipboard(r#"{"not_tspans":[]}"#).is_none());
    }

    #[test]
    fn svg_fragment_roundtrip_preserves_content_and_weight() {
        let src = vec![plain("hello "), bold("world")];
        let svg = tspans_to_svg_fragment(&src);
        assert!(svg.contains(r#"<text xmlns="http://www.w3.org/2000/svg">"#));
        assert!(svg.contains("<tspan>hello </tspan>"));
        assert!(svg.contains(r#"<tspan font-weight="bold">world</tspan>"#));
        let back = tspans_from_svg_fragment(&svg).unwrap();
        assert_eq!(back.len(), 2);
        assert_eq!(back[0].content, "hello ");
        assert!(back[0].font_weight.is_none());
        assert_eq!(back[1].content, "world");
        assert_eq!(back[1].font_weight.as_deref(), Some("bold"));
    }

    #[test]
    fn svg_fragment_escapes_and_unescapes_special_chars() {
        let src = vec![plain("< & >")];
        let svg = tspans_to_svg_fragment(&src);
        assert!(svg.contains("&lt; &amp; &gt;"));
        let back = tspans_from_svg_fragment(&svg).unwrap();
        assert_eq!(back[0].content, "< & >");
    }

    #[test]
    fn svg_fragment_from_rejects_missing_text_root() {
        assert!(tspans_from_svg_fragment("<span>hi</span>").is_none());
    }

    #[test]
    fn svg_fragment_text_decoration_round_trip() {
        let mut t = Tspan::default_tspan();
        t.content = "x".into();
        t.text_decoration = Some(vec!["underline".into(), "line-through".into()]);
        let svg = tspans_to_svg_fragment(&[t]);
        let back = tspans_from_svg_fragment(&svg).unwrap();
        let td = back[0].text_decoration.as_ref().unwrap();
        assert!(td.contains(&"underline".to_string()));
        assert!(td.contains(&"line-through".to_string()));
    }

    // ── jas:role wrapper tspan (Phase 1a) ───────────────────────────
    //
    // Paragraph wrapper tspans are tagged with jas:role="paragraph".
    // Phase 1a only persists the role marker through clipboard and
    // document SVG round-trips; paragraph attribute fields and
    // Enter/Backspace edit primitives land in Phase 1b.

    #[test]
    fn default_tspan_has_no_role() {
        assert!(Tspan::default_tspan().jas_role.is_none());
    }

    #[test]
    fn has_no_overrides_false_when_jas_role_set() {
        let mut t = Tspan::default_tspan();
        t.jas_role = Some("paragraph".into());
        assert!(!t.has_no_overrides());
    }

    #[test]
    fn svg_fragment_jas_role_round_trip() {
        let mut t = Tspan::default_tspan();
        t.content = "".into();
        t.jas_role = Some("paragraph".into());
        let svg = tspans_to_svg_fragment(&[t]);
        assert!(svg.contains(r#"jas:role="paragraph""#), "got: {}", svg);
        let back = tspans_from_svg_fragment(&svg).unwrap();
        assert_eq!(back.len(), 1);
        assert_eq!(back[0].jas_role.as_deref(), Some("paragraph"));
    }

    // ── Phase 3b panel-surface paragraph attrs ──────────────────────

    #[test]
    fn has_no_overrides_false_when_phase3b_attrs_set() {
        let mut t = Tspan::default_tspan();
        t.jas_left_indent = Some(12.0);
        assert!(!t.has_no_overrides());

        let mut t = Tspan::default_tspan();
        t.jas_hyphenate = Some(true);
        assert!(!t.has_no_overrides());

        let mut t = Tspan::default_tspan();
        t.jas_list_style = Some("bullet-disc".into());
        assert!(!t.has_no_overrides());
    }

    // ── Phase 1b1 remaining panel-surface paragraph attrs ──────────

    #[test]
    fn has_no_overrides_false_when_phase1b1_attrs_set() {
        let mut t = Tspan::default_tspan();
        t.text_align = Some("justify".into());
        assert!(!t.has_no_overrides());

        let mut t = Tspan::default_tspan();
        t.text_indent = Some(-12.0);
        assert!(!t.has_no_overrides());

        let mut t = Tspan::default_tspan();
        t.jas_space_before = Some(6.0);
        assert!(!t.has_no_overrides());
    }

    #[test]
    fn svg_fragment_phase1b1_attrs_round_trip() {
        let mut t = Tspan::default_tspan();
        t.content = "".into();
        t.jas_role = Some("paragraph".into());
        t.text_align = Some("justify".into());
        t.text_align_last = Some("center".into());
        t.text_indent = Some(-18.0);
        t.jas_space_before = Some(6.0);
        t.jas_space_after = Some(12.0);
        let svg = tspans_to_svg_fragment(&[t]);
        assert!(svg.contains(r#"text-align="justify""#), "got: {}", svg);
        assert!(svg.contains(r#"text-align-last="center""#));
        assert!(svg.contains(r#"text-indent="-18""#));
        assert!(svg.contains(r#"jas:space-before="6""#));
        assert!(svg.contains(r#"jas:space-after="12""#));
        let back = tspans_from_svg_fragment(&svg).unwrap();
        assert_eq!(back.len(), 1);
        assert_eq!(back[0].text_align.as_deref(), Some("justify"));
        assert_eq!(back[0].text_align_last.as_deref(), Some("center"));
        assert_eq!(back[0].text_indent, Some(-18.0));
        assert_eq!(back[0].jas_space_before, Some(6.0));
        assert_eq!(back[0].jas_space_after, Some(12.0));
    }

    #[test]
    fn svg_fragment_phase3b_attrs_round_trip() {
        let mut t = Tspan::default_tspan();
        t.content = "".into();
        t.jas_role = Some("paragraph".into());
        t.jas_left_indent = Some(18.0);
        t.jas_right_indent = Some(9.0);
        t.jas_hyphenate = Some(true);
        t.jas_hanging_punctuation = Some(true);
        t.jas_list_style = Some("bullet-disc".into());
        let svg = tspans_to_svg_fragment(&[t]);
        assert!(svg.contains(r#"jas:left-indent="18""#), "got: {}", svg);
        assert!(svg.contains(r#"jas:right-indent="9""#));
        assert!(svg.contains(r#"jas:hyphenate="true""#));
        assert!(svg.contains(r#"jas:hanging-punctuation="true""#));
        assert!(svg.contains(r#"jas:list-style="bullet-disc""#));
        let back = tspans_from_svg_fragment(&svg).unwrap();
        assert_eq!(back.len(), 1);
        assert_eq!(back[0].jas_left_indent, Some(18.0));
        assert_eq!(back[0].jas_right_indent, Some(9.0));
        assert_eq!(back[0].jas_hyphenate, Some(true));
        assert_eq!(back[0].jas_hanging_punctuation, Some(true));
        assert_eq!(back[0].jas_list_style.as_deref(), Some("bullet-disc"));
    }

    // ── char_to_tspan_pos / Affinity ────────────────────────────────

    #[test]
    fn char_to_tspan_pos_mid_first_tspan() {
        let base = vec![plain("foo"), bold("bar")];
        assert_eq!(char_to_tspan_pos(&base, 1, Affinity::Left), (0, 1));
        assert_eq!(char_to_tspan_pos(&base, 1, Affinity::Right), (0, 1));
    }

    #[test]
    fn char_to_tspan_pos_mid_later_tspan() {
        let base = vec![plain("foo"), bold("bar")];
        // char index 4 = "b|a|r"[1] → (1, 1)
        assert_eq!(char_to_tspan_pos(&base, 4, Affinity::Left), (1, 1));
    }

    #[test]
    fn char_to_tspan_pos_boundary_left_affinity() {
        let base = vec![plain("foo"), bold("bar")];
        // Boundary at char index 3 — Left picks end of tspan 0.
        assert_eq!(char_to_tspan_pos(&base, 3, Affinity::Left), (0, 3));
    }

    #[test]
    fn char_to_tspan_pos_boundary_right_affinity() {
        let base = vec![plain("foo"), bold("bar")];
        // Same boundary — Right picks start of tspan 1.
        assert_eq!(char_to_tspan_pos(&base, 3, Affinity::Right), (1, 0));
    }

    #[test]
    fn char_to_tspan_pos_final_boundary_always_end() {
        let base = vec![plain("foo"), bold("bar")];
        // End of content: both affinities resolve to the end of the last tspan.
        assert_eq!(char_to_tspan_pos(&base, 6, Affinity::Left), (1, 3));
        assert_eq!(char_to_tspan_pos(&base, 6, Affinity::Right), (1, 3));
    }

    #[test]
    fn char_to_tspan_pos_beyond_end_clamps() {
        let base = vec![plain("foo"), bold("bar")];
        assert_eq!(char_to_tspan_pos(&base, 999, Affinity::Left), (1, 3));
    }

    #[test]
    fn char_to_tspan_pos_empty_list() {
        let empty: Vec<Tspan> = vec![];
        assert_eq!(char_to_tspan_pos(&empty, 0, Affinity::Left), (0, 0));
        assert_eq!(char_to_tspan_pos(&empty, 5, Affinity::Left), (0, 0));
    }

    #[test]
    fn char_to_tspan_pos_skips_empty_tspans() {
        // Empty tspan in the middle should be passed through transparently.
        let base = vec![plain("fo"), plain(""), bold("bar")];
        // Boundary between "fo" (idx 0, len 2) and "" (idx 1, len 0):
        // Left stops at (0, 2), Right would fall through to (1, 0).
        assert_eq!(char_to_tspan_pos(&base, 2, Affinity::Left), (0, 2));
        assert_eq!(char_to_tspan_pos(&base, 2, Affinity::Right), (1, 0));
    }
}
