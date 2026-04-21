//! SVG import and export.
//!
//! Internal coordinates are in points (pt). SVG coordinates are in pixels (px).
//! Conversion factor: 96/72 (CSS px per pt at 96 DPI).

use std::collections::HashMap;
use std::rc::Rc;

use crate::document::document::Document;
use crate::geometry::element::*;
use crate::geometry::normalize::normalize_document;

const PT_TO_PX: f64 = 96.0 / 72.0;
const PX_TO_PT: f64 = 72.0 / 96.0;

fn px(v: f64) -> f64 {
    v * PT_TO_PX
}

fn pt(v: f64) -> f64 {
    v * PX_TO_PT
}

fn fmt(v: f64) -> String {
    let s = format!("{:.4}", v);
    let s = s.trim_end_matches('0');
    let s = s.trim_end_matches('.');
    s.to_string()
}

fn color_str(c: &Color) -> String {
    let (rv, gv, bv, a) = c.to_rgba();
    let r = (rv * 255.0).round() as u8;
    let g = (gv * 255.0).round() as u8;
    let b = (bv * 255.0).round() as u8;
    if a < 1.0 {
        format!("rgba({},{},{},{})", r, g, b, fmt(a))
    } else {
        format!("rgb({},{},{})", r, g, b)
    }
}

fn fill_attrs(fill: &Option<Fill>) -> String {
    match fill {
        None => " fill=\"none\"".to_string(),
        Some(f) => {
            let mut s = format!(" fill=\"{}\"", color_str(&f.color));
            if f.opacity < 1.0 {
                s.push_str(&format!(" fill-opacity=\"{}\"", fmt(f.opacity)));
            }
            s
        }
    }
}

fn stroke_attrs(stroke: &Option<Stroke>) -> String {
    match stroke {
        None => " stroke=\"none\"".to_string(),
        Some(s) => {
            let mut parts = vec![format!(" stroke=\"{}\"", color_str(&s.color))];
            parts.push(format!(" stroke-width=\"{}\"", fmt(px(s.width))));
            match s.linecap {
                LineCap::Round => parts.push(" stroke-linecap=\"round\"".to_string()),
                LineCap::Square => parts.push(" stroke-linecap=\"square\"".to_string()),
                _ => {}
            }
            match s.linejoin {
                LineJoin::Round => parts.push(" stroke-linejoin=\"round\"".to_string()),
                LineJoin::Bevel => parts.push(" stroke-linejoin=\"bevel\"".to_string()),
                _ => {}
            }
            if s.opacity < 1.0 {
                parts.push(format!(" stroke-opacity=\"{}\"", fmt(s.opacity)));
            }
            parts.join("")
        }
    }
}

fn transform_attr(t: &Option<Transform>) -> String {
    match t {
        None => String::new(),
        Some(t) => format!(
            " transform=\"matrix({},{},{},{},{},{})\"",
            fmt(t.a), fmt(t.b), fmt(t.c), fmt(t.d), fmt(px(t.e)), fmt(px(t.f))
        ),
    }
}

fn opacity_attr(opacity: f64) -> String {
    if opacity >= 1.0 {
        String::new()
    } else {
        format!(" opacity=\"{}\"", fmt(opacity))
    }
}

fn path_data(commands: &[PathCommand]) -> String {
    let mut parts = Vec::new();
    for cmd in commands {
        match cmd {
            PathCommand::MoveTo { x, y } => {
                parts.push(format!("M{},{}", fmt(px(*x)), fmt(px(*y))));
            }
            PathCommand::LineTo { x, y } => {
                parts.push(format!("L{},{}", fmt(px(*x)), fmt(px(*y))));
            }
            PathCommand::CurveTo { x1, y1, x2, y2, x, y } => {
                parts.push(format!(
                    "C{},{} {},{} {},{}",
                    fmt(px(*x1)), fmt(px(*y1)),
                    fmt(px(*x2)), fmt(px(*y2)),
                    fmt(px(*x)), fmt(px(*y))
                ));
            }
            PathCommand::SmoothCurveTo { x2, y2, x, y } => {
                parts.push(format!(
                    "S{},{} {},{}",
                    fmt(px(*x2)), fmt(px(*y2)),
                    fmt(px(*x)), fmt(px(*y))
                ));
            }
            PathCommand::QuadTo { x1, y1, x, y } => {
                parts.push(format!(
                    "Q{},{} {},{}",
                    fmt(px(*x1)), fmt(px(*y1)),
                    fmt(px(*x)), fmt(px(*y))
                ));
            }
            PathCommand::SmoothQuadTo { x, y } => {
                parts.push(format!("T{},{}", fmt(px(*x)), fmt(px(*y))));
            }
            PathCommand::ArcTo { rx, ry, x_rotation, large_arc, sweep, x, y } => {
                let la = if *large_arc { 1 } else { 0 };
                let sw = if *sweep { 1 } else { 0 };
                parts.push(format!(
                    "A{},{} {} {},{} {},{}",
                    fmt(px(*rx)), fmt(px(*ry)),
                    fmt(*x_rotation), la, sw,
                    fmt(px(*x)), fmt(px(*y))
                ));
            }
            PathCommand::ClosePath => {
                parts.push("Z".to_string());
            }
        }
    }
    parts.join(" ")
}

fn escape_xml(s: &str) -> String {
    s.replace('&', "&amp;")
        .replace('<', "&lt;")
        .replace('>', "&gt;")
        .replace('"', "&quot;")
}

pub fn element_svg(elem: &Element, indent: &str) -> String {
    match elem {
        Element::Line(e) => {
            format!(
                "{}<line x1=\"{}\" y1=\"{}\" x2=\"{}\" y2=\"{}\"{}{}{}/>\n",
                indent,
                fmt(px(e.x1)), fmt(px(e.y1)), fmt(px(e.x2)), fmt(px(e.y2)),
                stroke_attrs(&e.stroke),
                opacity_attr(e.common.opacity),
                transform_attr(&e.common.transform),
            )
        }
        Element::Rect(e) => {
            let mut rxy = String::new();
            if e.rx > 0.0 {
                rxy.push_str(&format!(" rx=\"{}\"", fmt(px(e.rx))));
            }
            if e.ry > 0.0 {
                rxy.push_str(&format!(" ry=\"{}\"", fmt(px(e.ry))));
            }
            format!(
                "{}<rect x=\"{}\" y=\"{}\" width=\"{}\" height=\"{}\"{}{}{}{}{}/>\n",
                indent,
                fmt(px(e.x)), fmt(px(e.y)), fmt(px(e.width)), fmt(px(e.height)),
                rxy,
                fill_attrs(&e.fill), stroke_attrs(&e.stroke),
                opacity_attr(e.common.opacity), transform_attr(&e.common.transform),
            )
        }
        Element::Circle(e) => {
            format!(
                "{}<circle cx=\"{}\" cy=\"{}\" r=\"{}\"{}{}{}{}/>\n",
                indent,
                fmt(px(e.cx)), fmt(px(e.cy)), fmt(px(e.r)),
                fill_attrs(&e.fill), stroke_attrs(&e.stroke),
                opacity_attr(e.common.opacity), transform_attr(&e.common.transform),
            )
        }
        Element::Ellipse(e) => {
            format!(
                "{}<ellipse cx=\"{}\" cy=\"{}\" rx=\"{}\" ry=\"{}\"{}{}{}{}/>\n",
                indent,
                fmt(px(e.cx)), fmt(px(e.cy)), fmt(px(e.rx)), fmt(px(e.ry)),
                fill_attrs(&e.fill), stroke_attrs(&e.stroke),
                opacity_attr(e.common.opacity), transform_attr(&e.common.transform),
            )
        }
        Element::Polyline(e) => {
            let ps: String = e.points.iter()
                .map(|(x, y)| format!("{},{}", fmt(px(*x)), fmt(px(*y))))
                .collect::<Vec<_>>()
                .join(" ");
            format!(
                "{}<polyline points=\"{}\"{}{}{}{}/>\n",
                indent, ps,
                fill_attrs(&e.fill), stroke_attrs(&e.stroke),
                opacity_attr(e.common.opacity), transform_attr(&e.common.transform),
            )
        }
        Element::Polygon(e) => {
            let ps: String = e.points.iter()
                .map(|(x, y)| format!("{},{}", fmt(px(*x)), fmt(px(*y))))
                .collect::<Vec<_>>()
                .join(" ");
            format!(
                "{}<polygon points=\"{}\"{}{}{}{}/>\n",
                indent, ps,
                fill_attrs(&e.fill), stroke_attrs(&e.stroke),
                opacity_attr(e.common.opacity), transform_attr(&e.common.transform),
            )
        }
        Element::Path(e) => {
            format!(
                "{}<path d=\"{}\"{}{}{}{}/>\n",
                indent,
                path_data(&e.d),
                fill_attrs(&e.fill), stroke_attrs(&e.stroke),
                opacity_attr(e.common.opacity), transform_attr(&e.common.transform),
            )
        }
        Element::Text(e) => {
            let mut area_attrs = String::new();
            if e.width > 0.0 && e.height > 0.0 {
                area_attrs = format!(
                    " style=\"inline-size: {}px; white-space: pre-wrap;\"",
                    fmt(px(e.width))
                );
            }
            let fw_attr = if e.font_weight != "normal" {
                format!(" font-weight=\"{}\"", e.font_weight)
            } else { String::new() };
            let fst_attr = if e.font_style != "normal" {
                format!(" font-style=\"{}\"", e.font_style)
            } else { String::new() };
            let td_attr = if e.text_decoration != "none" && !e.text_decoration.is_empty() {
                format!(" text-decoration=\"{}\"", e.text_decoration)
            } else { String::new() };
            let tt_attr = if !e.text_transform.is_empty() {
                format!(" text-transform=\"{}\"", e.text_transform)
            } else { String::new() };
            let fv_attr = if !e.font_variant.is_empty() {
                format!(" font-variant=\"{}\"", e.font_variant)
            } else { String::new() };
            let bs_attr = if !e.baseline_shift.is_empty() {
                format!(" baseline-shift=\"{}\"", e.baseline_shift)
            } else { String::new() };
            let lh_attr = if !e.line_height.is_empty() {
                format!(" line-height=\"{}\"", e.line_height)
            } else { String::new() };
            let ls_attr = if !e.letter_spacing.is_empty() {
                format!(" letter-spacing=\"{}\"", e.letter_spacing)
            } else { String::new() };
            let lang_attr = if !e.xml_lang.is_empty() {
                format!(" xml:lang=\"{}\"", escape_xml(&e.xml_lang))
            } else { String::new() };
            let aa_attr = if !e.aa_mode.is_empty() {
                format!(" urn:jas:1:aa-mode=\"{}\"", escape_xml(&e.aa_mode))
            } else { String::new() };
            let rotate_attr = if !e.rotate.is_empty() {
                format!(" rotate=\"{}\"", e.rotate)
            } else { String::new() };
            let hs_attr = if !e.horizontal_scale.is_empty() {
                format!(" horizontal-scale=\"{}\"", e.horizontal_scale)
            } else { String::new() };
            let vs_attr = if !e.vertical_scale.is_empty() {
                format!(" vertical-scale=\"{}\"", e.vertical_scale)
            } else { String::new() };
            let kern_attr = if !e.kerning.is_empty() {
                format!(" urn:jas:1:kerning-mode=\"{}\"", escape_xml(&e.kerning))
            } else { String::new() };
            let svg_y = e.y + e.font_size * 0.8;
            let is_flat = e.tspans.len() == 1 && e.tspans[0].has_no_overrides();
            if is_flat {
                // Pre-Tspan-compatible emission: no <tspan> wrapper.
                format!(
                    "{}<text x=\"{}\" y=\"{}\" font-family=\"{}\" font-size=\"{}\"{}{}{}{}{}{}{}{}{}{}{}{}{}{}{}{}{}{}>{}</text>\n",
                    indent,
                    fmt(px(e.x)), fmt(px(svg_y)),
                    escape_xml(&e.font_family), fmt(px(e.font_size)),
                    fw_attr, fst_attr, td_attr, tt_attr, fv_attr, bs_attr,
                    lh_attr, ls_attr, lang_attr, aa_attr,
                    rotate_attr, hs_attr, vs_attr, kern_attr,
                    area_attrs,
                    fill_attrs(&e.fill), stroke_attrs(&e.stroke),
                    opacity_attr(e.common.opacity),
                    escape_xml(&e.content()),
                )
            } else {
                // Multi-tspan or overriding tspan: wrap children, carry
                // xml:space="preserve" so inter-glyph whitespace is stable
                // across round-trips (TSPAN.md SVG serialization).
                let tspan_xml: String = e.tspans.iter().map(tspan_svg).collect();
                format!(
                    "{}<text x=\"{}\" y=\"{}\" font-family=\"{}\" font-size=\"{}\"{}{}{}{}{}{}{}{}{}{}{}{}{}{}{}{}{}{} xml:space=\"preserve\">{}</text>\n",
                    indent,
                    fmt(px(e.x)), fmt(px(svg_y)),
                    escape_xml(&e.font_family), fmt(px(e.font_size)),
                    fw_attr, fst_attr, td_attr, tt_attr, fv_attr, bs_attr,
                    lh_attr, ls_attr, lang_attr, aa_attr,
                    rotate_attr, hs_attr, vs_attr, kern_attr,
                    area_attrs,
                    fill_attrs(&e.fill), stroke_attrs(&e.stroke),
                    opacity_attr(e.common.opacity),
                    tspan_xml,
                )
            }
        }
        Element::TextPath(e) => {
            let offset_attr = if e.start_offset > 0.0 {
                format!(" startOffset=\"{}%\"", fmt(e.start_offset * 100.0))
            } else { String::new() };
            let fw_attr = if e.font_weight != "normal" {
                format!(" font-weight=\"{}\"", e.font_weight)
            } else { String::new() };
            let fst_attr = if e.font_style != "normal" {
                format!(" font-style=\"{}\"", e.font_style)
            } else { String::new() };
            let td_attr = if e.text_decoration != "none" && !e.text_decoration.is_empty() {
                format!(" text-decoration=\"{}\"", e.text_decoration)
            } else { String::new() };
            let tt_attr = if !e.text_transform.is_empty() {
                format!(" text-transform=\"{}\"", e.text_transform)
            } else { String::new() };
            let fv_attr = if !e.font_variant.is_empty() {
                format!(" font-variant=\"{}\"", e.font_variant)
            } else { String::new() };
            let bs_attr = if !e.baseline_shift.is_empty() {
                format!(" baseline-shift=\"{}\"", e.baseline_shift)
            } else { String::new() };
            let lh_attr = if !e.line_height.is_empty() {
                format!(" line-height=\"{}\"", e.line_height)
            } else { String::new() };
            let ls_attr = if !e.letter_spacing.is_empty() {
                format!(" letter-spacing=\"{}\"", e.letter_spacing)
            } else { String::new() };
            let lang_attr = if !e.xml_lang.is_empty() {
                format!(" xml:lang=\"{}\"", escape_xml(&e.xml_lang))
            } else { String::new() };
            let aa_attr = if !e.aa_mode.is_empty() {
                format!(" urn:jas:1:aa-mode=\"{}\"", escape_xml(&e.aa_mode))
            } else { String::new() };
            let rotate_attr = if !e.rotate.is_empty() {
                format!(" rotate=\"{}\"", e.rotate)
            } else { String::new() };
            let hs_attr = if !e.horizontal_scale.is_empty() {
                format!(" horizontal-scale=\"{}\"", e.horizontal_scale)
            } else { String::new() };
            let vs_attr = if !e.vertical_scale.is_empty() {
                format!(" vertical-scale=\"{}\"", e.vertical_scale)
            } else { String::new() };
            let kern_attr = if !e.kerning.is_empty() {
                format!(" urn:jas:1:kerning-mode=\"{}\"", escape_xml(&e.kerning))
            } else { String::new() };
            let is_flat = e.tspans.len() == 1 && e.tspans[0].has_no_overrides();
            let (space_attr, body) = if is_flat {
                (String::new(), escape_xml(&e.content()))
            } else {
                (
                    " xml:space=\"preserve\"".to_string(),
                    e.tspans.iter().map(tspan_svg).collect::<String>(),
                )
            };
            format!(
                "{}<text{}{} font-family=\"{}\" font-size=\"{}\"{}{}{}{}{}{}{}{}{}{}{}{}{}{}{}{}><textPath path=\"{}\"{}{}>{}</textPath></text>\n",
                indent,
                fill_attrs(&e.fill), stroke_attrs(&e.stroke),
                escape_xml(&e.font_family), fmt(px(e.font_size)),
                fw_attr, fst_attr, td_attr, tt_attr, fv_attr, bs_attr,
                lh_attr, ls_attr, lang_attr, aa_attr,
                rotate_attr, hs_attr, vs_attr, kern_attr,
                opacity_attr(e.common.opacity), transform_attr(&e.common.transform),
                path_data(&e.d), offset_attr, space_attr,
                body,
            )
        }
        Element::Layer(e) => {
            let label = if !e.name.is_empty() {
                format!(" inkscape:label=\"{}\"", escape_xml(&e.name))
            } else { String::new() };
            let mut lines = vec![format!(
                "{}<g{}{}{}>",
                indent, label,
                opacity_attr(e.common.opacity), transform_attr(&e.common.transform),
            )];
            let child_indent = format!("{}  ", indent);
            for child in &e.children {
                lines.push(element_svg(child, &child_indent));
            }
            lines.push(format!("{}</g>", indent));
            lines.join("\n")
        }
        Element::Group(e) => {
            let mut lines = vec![format!(
                "{}<g{}{}>",
                indent,
                opacity_attr(e.common.opacity), transform_attr(&e.common.transform),
            )];
            let child_indent = format!("{}  ", indent);
            for child in &e.children {
                lines.push(element_svg(child, &child_indent));
            }
            lines.push(format!("{}</g>", indent));
            lines.join("\n")
        }
        // Live elements (phase 1): emit as a group of operands so SVG
        // export remains lossless-ish. Phase 2 will replace this with
        // the evaluated geometry once the boolean pipeline is wired.
        Element::Live(v) => match v {
            crate::geometry::live::LiveVariant::CompoundShape(cs) => {
                let mut lines = vec![format!(
                    "{}<g data-jas-live=\"compound_shape\"{}{}>",
                    indent,
                    opacity_attr(cs.common.opacity),
                    transform_attr(&cs.common.transform),
                )];
                let child_indent = format!("{}  ", indent);
                for child in &cs.operands {
                    lines.push(element_svg(child, &child_indent));
                }
                lines.push(format!("{}</g>", indent));
                lines.join("\n")
            }
        },
    }
}

const INKSCAPE_NS: &str = "http://www.inkscape.org/namespaces/inkscape";

/// Convert a Document to an SVG string.
pub fn document_to_svg(doc: &Document) -> String {
    let (bx, by, bw, bh) = doc.bounds();
    let vb = format!(
        "{} {} {} {}",
        fmt(px(bx)), fmt(px(by)), fmt(px(bw)), fmt(px(bh))
    );
    let mut lines = vec![
        "<?xml version=\"1.0\" encoding=\"UTF-8\"?>".to_string(),
        format!(
            "<svg xmlns=\"http://www.w3.org/2000/svg\" xmlns:inkscape=\"{}\" viewBox=\"{}\" width=\"{}\" height=\"{}\">",
            INKSCAPE_NS, vb, fmt(px(bw)), fmt(px(bh))
        ),
    ];
    for layer in &doc.layers {
        lines.push(element_svg(layer, "  "));
    }
    lines.push("</svg>".to_string());
    lines.join("\n")
}

// ---------------------------------------------------------------------------
// SVG Import: simple XML parser (no external crate)
// ---------------------------------------------------------------------------

/// Minimal XML element for SVG parsing.
#[derive(Debug)]
struct XmlNode {
    tag: String,
    attrs: HashMap<String, String>,
    children: Vec<XmlNode>,
    text: String,
}

/// Parse a minimal subset of XML sufficient for SVG import.
/// Not a full XML parser — handles elements, attributes, text, self-closing tags.
fn parse_xml(input: &str) -> Option<XmlNode> {
    let input = input.trim();
    // Skip XML declaration
    let input = if input.starts_with("<?xml") {
        if let Some(pos) = input.find("?>") {
            input[pos + 2..].trim()
        } else {
            input
        }
    } else {
        input
    };
    // Skip DOCTYPE
    let input = if input.starts_with("<!DOCTYPE") {
        if let Some(pos) = input.find('>') {
            input[pos + 1..].trim()
        } else {
            input
        }
    } else {
        input
    };
    let (node, _) = parse_xml_node(input)?;
    Some(node)
}

fn parse_xml_node(input: &str) -> Option<(XmlNode, &str)> {
    let input = input.trim();
    if !input.starts_with('<') {
        return None;
    }
    let input = &input[1..]; // skip '<'

    // Parse tag name
    let (tag, rest) = parse_tag_name(input)?;

    // Parse attributes
    let (attrs, rest, self_closing) = parse_attributes(rest)?;

    if self_closing {
        return Some((XmlNode { tag, attrs, children: Vec::new(), text: String::new() }, rest));
    }

    // Parse children and text until closing tag
    let mut children = Vec::new();
    let mut text = String::new();
    let mut rest = rest;
    let _close_tag = format!("</{}", tag.split(':').next_back().unwrap_or(&tag));
    // Also handle namespaced close tags
    loop {
        rest = rest.trim_start();
        if rest.is_empty() {
            break;
        }
        // Check for closing tag (handle namespace stripping)
        if rest.starts_with("</") {
            // Find the end of the close tag
            if let Some(pos) = rest.find('>') {
                rest = &rest[pos + 1..];
                break;
            }
            break;
        }
        // Check for comment
        if rest.starts_with("<!--") {
            if let Some(pos) = rest.find("-->") {
                rest = &rest[pos + 3..];
                continue;
            }
            break;
        }
        // Try to parse child element
        if rest.starts_with('<') {
            if let Some((child, new_rest)) = parse_xml_node(rest) {
                children.push(child);
                rest = new_rest;
                continue;
            }
            break;
        }
        // Text content
        if let Some(pos) = rest.find('<') {
            text.push_str(&unescape_xml(&rest[..pos]));
            rest = &rest[pos..];
        } else {
            text.push_str(&unescape_xml(rest));
            rest = "";
            break;
        }
    }

    Some((XmlNode { tag, attrs, children, text }, rest))
}

fn parse_tag_name(input: &str) -> Option<(String, &str)> {
    let end = input.find(|c: char| c.is_whitespace() || c == '/' || c == '>')?;
    let tag = input[..end].to_string();
    Some((tag, &input[end..]))
}

fn parse_attributes(mut input: &str) -> Option<(HashMap<String, String>, &str, bool)> {
    let mut attrs = HashMap::new();
    loop {
        input = input.trim_start();
        if let Some(rest) = input.strip_prefix("/>") {
            return Some((attrs, rest, true));
        }
        if let Some(rest) = input.strip_prefix('>') {
            return Some((attrs, rest, false));
        }
        // Parse attribute name
        let eq_pos = input.find('=')?;
        let name = input[..eq_pos].trim().to_string();
        input = input[eq_pos + 1..].trim_start();
        // Parse attribute value
        let quote = input.as_bytes().first()?;
        if *quote != b'"' && *quote != b'\'' {
            return None;
        }
        let q = *quote as char;
        input = &input[1..];
        let end = input.find(q)?;
        let value = input[..end].to_string();
        input = &input[end + 1..];
        attrs.insert(name, value);
    }
}

fn unescape_xml(s: &str) -> String {
    s.replace("&amp;", "&")
        .replace("&lt;", "<")
        .replace("&gt;", ">")
        .replace("&quot;", "\"")
        .replace("&apos;", "'")
}

// ---------------------------------------------------------------------------
// SVG element parsing
// ---------------------------------------------------------------------------

/// Emit a single Tspan as an SVG `<tspan ...>content</tspan>` element.
/// Only overridden attributes are emitted (inherited values are absent).
fn tspan_svg(t: &crate::geometry::tspan::Tspan) -> String {
    let mut attrs = String::new();
    if let Some(v) = &t.font_family {
        attrs.push_str(&format!(" font-family=\"{}\"", escape_xml(v)));
    }
    if let Some(v) = t.font_size {
        attrs.push_str(&format!(" font-size=\"{}\"", fmt(px(v))));
    }
    if let Some(v) = &t.font_weight {
        attrs.push_str(&format!(" font-weight=\"{}\"", escape_xml(v)));
    }
    if let Some(v) = &t.font_style {
        attrs.push_str(&format!(" font-style=\"{}\"", escape_xml(v)));
    }
    if let Some(v) = &t.text_decoration
        && !v.is_empty()
    {
        let joined = v.join(" ");
        attrs.push_str(&format!(
            " text-decoration=\"{}\"",
            escape_xml(&joined)
        ));
    }
    // Per-tspan rotation. Our model stores a single f64 per tspan, so
    // per-glyph varying rotations require each glyph to live in its
    // own tspan (enforced by the Touch Type tool). SVG's multi-value
    // `rotate="a1 a2 …"` form is handled on the parse side by
    // splitting the tspan into one per glyph — see [`parse_tspan`].
    if let Some(v) = t.rotate {
        attrs.push_str(&format!(" rotate=\"{}\"", fmt(v)));
    }
    if let Some(v) = &t.jas_role {
        attrs.push_str(&format!(" urn:jas:1:role=\"{}\"", escape_xml(v)));
    }
    if let Some(v) = t.jas_left_indent {
        attrs.push_str(&format!(" urn:jas:1:left-indent=\"{}\"", fmt(v)));
    }
    if let Some(v) = t.jas_right_indent {
        attrs.push_str(&format!(" urn:jas:1:right-indent=\"{}\"", fmt(v)));
    }
    if let Some(v) = t.jas_hyphenate {
        attrs.push_str(&format!(" urn:jas:1:hyphenate=\"{}\"", v));
    }
    if let Some(v) = t.jas_hanging_punctuation {
        attrs.push_str(&format!(" urn:jas:1:hanging-punctuation=\"{}\"", v));
    }
    if let Some(v) = &t.jas_list_style {
        attrs.push_str(&format!(" urn:jas:1:list-style=\"{}\"", escape_xml(v)));
    }
    if let Some(v) = &t.text_align {
        attrs.push_str(&format!(" text-align=\"{}\"", escape_xml(v)));
    }
    if let Some(v) = &t.text_align_last {
        attrs.push_str(&format!(" text-align-last=\"{}\"", escape_xml(v)));
    }
    if let Some(v) = t.text_indent {
        attrs.push_str(&format!(" text-indent=\"{}\"", fmt(v)));
    }
    if let Some(v) = t.jas_space_before {
        attrs.push_str(&format!(" urn:jas:1:space-before=\"{}\"", fmt(v)));
    }
    if let Some(v) = t.jas_space_after {
        attrs.push_str(&format!(" urn:jas:1:space-after=\"{}\"", fmt(v)));
    }
    if let Some(v) = t.jas_word_spacing_min {
        attrs.push_str(&format!(" urn:jas:1:word-spacing-min=\"{}\"", fmt(v)));
    }
    if let Some(v) = t.jas_word_spacing_desired {
        attrs.push_str(&format!(" urn:jas:1:word-spacing-desired=\"{}\"", fmt(v)));
    }
    if let Some(v) = t.jas_word_spacing_max {
        attrs.push_str(&format!(" urn:jas:1:word-spacing-max=\"{}\"", fmt(v)));
    }
    if let Some(v) = t.jas_letter_spacing_min {
        attrs.push_str(&format!(" urn:jas:1:letter-spacing-min=\"{}\"", fmt(v)));
    }
    if let Some(v) = t.jas_letter_spacing_desired {
        attrs.push_str(&format!(" urn:jas:1:letter-spacing-desired=\"{}\"", fmt(v)));
    }
    if let Some(v) = t.jas_letter_spacing_max {
        attrs.push_str(&format!(" urn:jas:1:letter-spacing-max=\"{}\"", fmt(v)));
    }
    if let Some(v) = t.jas_glyph_scaling_min {
        attrs.push_str(&format!(" urn:jas:1:glyph-scaling-min=\"{}\"", fmt(v)));
    }
    if let Some(v) = t.jas_glyph_scaling_desired {
        attrs.push_str(&format!(" urn:jas:1:glyph-scaling-desired=\"{}\"", fmt(v)));
    }
    if let Some(v) = t.jas_glyph_scaling_max {
        attrs.push_str(&format!(" urn:jas:1:glyph-scaling-max=\"{}\"", fmt(v)));
    }
    if let Some(v) = t.jas_auto_leading {
        attrs.push_str(&format!(" urn:jas:1:auto-leading=\"{}\"", fmt(v)));
    }
    if let Some(v) = &t.jas_single_word_justify {
        attrs.push_str(&format!(" urn:jas:1:single-word-justify=\"{}\"", escape_xml(v)));
    }
    if let Some(v) = t.jas_hyphenate_min_word {
        attrs.push_str(&format!(" urn:jas:1:hyphenate-min-word=\"{}\"", fmt(v)));
    }
    if let Some(v) = t.jas_hyphenate_min_before {
        attrs.push_str(&format!(" urn:jas:1:hyphenate-min-before=\"{}\"", fmt(v)));
    }
    if let Some(v) = t.jas_hyphenate_min_after {
        attrs.push_str(&format!(" urn:jas:1:hyphenate-min-after=\"{}\"", fmt(v)));
    }
    if let Some(v) = t.jas_hyphenate_limit {
        attrs.push_str(&format!(" urn:jas:1:hyphenate-limit=\"{}\"", fmt(v)));
    }
    if let Some(v) = t.jas_hyphenate_zone {
        attrs.push_str(&format!(" urn:jas:1:hyphenate-zone=\"{}\"", fmt(v)));
    }
    if let Some(v) = t.jas_hyphenate_bias {
        attrs.push_str(&format!(" urn:jas:1:hyphenate-bias=\"{}\"", fmt(v)));
    }
    if let Some(v) = t.jas_hyphenate_capitalized {
        attrs.push_str(&format!(" urn:jas:1:hyphenate-capitalized=\"{}\"", v));
    }
    format!("<tspan{}>{}</tspan>", attrs, escape_xml(&t.content))
}

/// Parse an SVG `<tspan>` child node into one or more Tspans.
///
/// Returns a `Vec` so SVG's multi-value `rotate="a b c …"` syntax can
/// be expanded into one tspan per glyph (each carrying its own rotate
/// angle). The single-value case returns a one-element vec. Ids are
/// left at `0`; the caller assigns fresh sequential ids across the
/// whole tspan list.
fn parse_tspan(node: &XmlNode) -> Vec<crate::geometry::tspan::Tspan> {
    use crate::geometry::tspan::Tspan;
    let base = Tspan {
        id: 0,
        content: node.text.clone(),
        font_family: node.attrs.get("font-family").cloned(),
        font_size: node
            .attrs
            .get("font-size")
            .and_then(|s| s.parse::<f64>().ok())
            .map(pt),
        font_weight: node.attrs.get("font-weight").cloned(),
        font_style: node.attrs.get("font-style").cloned(),
        text_decoration: node.attrs.get("text-decoration").map(|s| {
            let mut parts: Vec<String> = s
                .split_whitespace()
                .filter(|x| *x != "none" && !x.is_empty())
                .map(String::from)
                .collect();
            parts.sort();
            parts
        }),
        jas_role: node.attrs.get("urn:jas:1:role").cloned(),
        jas_left_indent: node.attrs.get("urn:jas:1:left-indent")
            .and_then(|s| s.parse::<f64>().ok()),
        jas_right_indent: node.attrs.get("urn:jas:1:right-indent")
            .and_then(|s| s.parse::<f64>().ok()),
        jas_hyphenate: node.attrs.get("urn:jas:1:hyphenate")
            .map(|v| v == "true"),
        jas_hanging_punctuation: node.attrs.get("urn:jas:1:hanging-punctuation")
            .map(|v| v == "true"),
        jas_list_style: node.attrs.get("urn:jas:1:list-style").cloned(),
        text_align: node.attrs.get("text-align").cloned(),
        text_align_last: node.attrs.get("text-align-last").cloned(),
        text_indent: node.attrs.get("text-indent")
            .and_then(|s| s.parse::<f64>().ok()),
        jas_space_before: node.attrs.get("urn:jas:1:space-before")
            .and_then(|s| s.parse::<f64>().ok()),
        jas_space_after: node.attrs.get("urn:jas:1:space-after")
            .and_then(|s| s.parse::<f64>().ok()),
        jas_word_spacing_min: node.attrs.get("urn:jas:1:word-spacing-min")
            .and_then(|s| s.parse::<f64>().ok()),
        jas_word_spacing_desired: node.attrs.get("urn:jas:1:word-spacing-desired")
            .and_then(|s| s.parse::<f64>().ok()),
        jas_word_spacing_max: node.attrs.get("urn:jas:1:word-spacing-max")
            .and_then(|s| s.parse::<f64>().ok()),
        jas_letter_spacing_min: node.attrs.get("urn:jas:1:letter-spacing-min")
            .and_then(|s| s.parse::<f64>().ok()),
        jas_letter_spacing_desired: node.attrs.get("urn:jas:1:letter-spacing-desired")
            .and_then(|s| s.parse::<f64>().ok()),
        jas_letter_spacing_max: node.attrs.get("urn:jas:1:letter-spacing-max")
            .and_then(|s| s.parse::<f64>().ok()),
        jas_glyph_scaling_min: node.attrs.get("urn:jas:1:glyph-scaling-min")
            .and_then(|s| s.parse::<f64>().ok()),
        jas_glyph_scaling_desired: node.attrs.get("urn:jas:1:glyph-scaling-desired")
            .and_then(|s| s.parse::<f64>().ok()),
        jas_glyph_scaling_max: node.attrs.get("urn:jas:1:glyph-scaling-max")
            .and_then(|s| s.parse::<f64>().ok()),
        jas_auto_leading: node.attrs.get("urn:jas:1:auto-leading")
            .and_then(|s| s.parse::<f64>().ok()),
        jas_single_word_justify: node.attrs.get("urn:jas:1:single-word-justify").cloned(),
        jas_hyphenate_min_word: node.attrs.get("urn:jas:1:hyphenate-min-word")
            .and_then(|s| s.parse::<f64>().ok()),
        jas_hyphenate_min_before: node.attrs.get("urn:jas:1:hyphenate-min-before")
            .and_then(|s| s.parse::<f64>().ok()),
        jas_hyphenate_min_after: node.attrs.get("urn:jas:1:hyphenate-min-after")
            .and_then(|s| s.parse::<f64>().ok()),
        jas_hyphenate_limit: node.attrs.get("urn:jas:1:hyphenate-limit")
            .and_then(|s| s.parse::<f64>().ok()),
        jas_hyphenate_zone: node.attrs.get("urn:jas:1:hyphenate-zone")
            .and_then(|s| s.parse::<f64>().ok()),
        jas_hyphenate_bias: node.attrs.get("urn:jas:1:hyphenate-bias")
            .and_then(|s| s.parse::<f64>().ok()),
        jas_hyphenate_capitalized: node.attrs.get("urn:jas:1:hyphenate-capitalized")
            .map(|v| v == "true"),
        ..Tspan::default_tspan()
    };
    // Multi-value rotate: SVG allows `rotate="a1 a2 a3 …"` on a tspan,
    // where each angle applies to the corresponding glyph. Our model
    // represents this by splitting the tspan into one per glyph.
    let rotate_vals: Vec<f64> = node
        .attrs
        .get("rotate")
        .map(|s| {
            s.split_whitespace()
                .filter_map(|x| x.parse::<f64>().ok())
                .collect()
        })
        .unwrap_or_default();
    let chars: Vec<char> = base.content.chars().collect();
    match rotate_vals.len() {
        0 => vec![base],
        1 => {
            let mut t = base;
            t.rotate = Some(rotate_vals[0]);
            vec![t]
        }
        _ if chars.len() <= 1 => {
            // Multi-value but content is at most one char — first
            // angle applies; extras are harmless.
            let mut t = base;
            t.rotate = Some(rotate_vals[0]);
            vec![t]
        }
        _ => {
            // Split the tspan into one per glyph. Each inherits
            // the base's override fields and gets the matching
            // rotate angle; the last angle is reused for any
            // trailing glyphs past the end of the list (per SVG).
            let last_angle = *rotate_vals.last().unwrap();
            chars
                .into_iter()
                .enumerate()
                .map(|(i, c)| {
                    let mut t = base.clone();
                    t.content = c.to_string();
                    t.rotate = Some(*rotate_vals.get(i).unwrap_or(&last_angle));
                    t
                })
                .collect()
        }
    }
}

fn strip_ns(tag: &str) -> &str {
    if let Some(pos) = tag.rfind('}') {
        &tag[pos + 1..]
    } else if let Some(pos) = tag.find(':') {
        &tag[pos + 1..]
    } else {
        tag
    }
}

fn get_f(node: &XmlNode, name: &str, default: f64) -> f64 {
    node.attrs.get(name)
        .and_then(|s| s.parse::<f64>().ok())
        .unwrap_or(default)
}

fn get_s<'a>(node: &'a XmlNode, name: &str, default: &'a str) -> &'a str {
    node.attrs.get(name).map(|s| s.as_str()).unwrap_or(default)
}

fn parse_color(s: &str) -> Option<Color> {
    let s = s.trim();
    if s == "none" {
        return None;
    }
    // Named colors
    if let Some(&(r, g, b)) = get_named_colors().get(s.to_lowercase().as_str()) {
        return Some(Color::Rgb { r: r as f64 / 255.0, g: g as f64 / 255.0, b: b as f64 / 255.0, a: 1.0 });
    }
    // Hex
    if let Some(h) = s.strip_prefix('#') {
        if h.len() == 3 {
            let r = u8::from_str_radix(&h[0..1].repeat(2), 16).ok()? as f64 / 255.0;
            let g = u8::from_str_radix(&h[1..2].repeat(2), 16).ok()? as f64 / 255.0;
            let b = u8::from_str_radix(&h[2..3].repeat(2), 16).ok()? as f64 / 255.0;
            return Some(Color::Rgb { r, g, b, a: 1.0 });
        }
        if h.len() == 4 {
            let r = u8::from_str_radix(&h[0..1].repeat(2), 16).ok()? as f64 / 255.0;
            let g = u8::from_str_radix(&h[1..2].repeat(2), 16).ok()? as f64 / 255.0;
            let b = u8::from_str_radix(&h[2..3].repeat(2), 16).ok()? as f64 / 255.0;
            let a = u8::from_str_radix(&h[3..4].repeat(2), 16).ok()? as f64 / 255.0;
            return Some(Color::Rgb { r, g, b, a });
        }
        if h.len() == 6 {
            let r = u8::from_str_radix(&h[0..2], 16).ok()? as f64 / 255.0;
            let g = u8::from_str_radix(&h[2..4], 16).ok()? as f64 / 255.0;
            let b = u8::from_str_radix(&h[4..6], 16).ok()? as f64 / 255.0;
            return Some(Color::Rgb { r, g, b, a: 1.0 });
        }
        if h.len() == 8 {
            let r = u8::from_str_radix(&h[0..2], 16).ok()? as f64 / 255.0;
            let g = u8::from_str_radix(&h[2..4], 16).ok()? as f64 / 255.0;
            let b = u8::from_str_radix(&h[4..6], 16).ok()? as f64 / 255.0;
            let a = u8::from_str_radix(&h[6..8], 16).ok()? as f64 / 255.0;
            return Some(Color::Rgb { r, g, b, a });
        }
        return None;
    }
    // rgb()/rgba()
    if s.starts_with("rgb") {
        let inner = s.split('(').nth(1)?.trim_end_matches(')');
        let parts: Vec<&str> = inner.split(',').collect();
        if parts.len() >= 3 {
            let r = parts[0].trim().parse::<f64>().ok()? / 255.0;
            let g = parts[1].trim().parse::<f64>().ok()? / 255.0;
            let b = parts[2].trim().parse::<f64>().ok()? / 255.0;
            let a = if parts.len() > 3 { parts[3].trim().parse::<f64>().ok()? } else { 1.0 };
            return Some(Color::Rgb { r, g, b, a });
        }
    }
    None
}

fn parse_fill(node: &XmlNode) -> Option<Fill> {
    let val = node.attrs.get("fill")?;
    if val == "none" {
        return None;
    }
    let opacity = get_f(node, "fill-opacity", 1.0);
    Some(Fill { color: parse_color(val)?, opacity })
}

fn parse_stroke(node: &XmlNode) -> Option<Stroke> {
    let val = node.attrs.get("stroke")?;
    if val == "none" {
        return None;
    }
    let color = parse_color(val)?;
    let width = get_f(node, "stroke-width", 1.0) * PX_TO_PT;
    let lc = match get_s(node, "stroke-linecap", "butt") {
        "round" => LineCap::Round,
        "square" => LineCap::Square,
        _ => LineCap::Butt,
    };
    let lj = match get_s(node, "stroke-linejoin", "miter") {
        "round" => LineJoin::Round,
        "bevel" => LineJoin::Bevel,
        _ => LineJoin::Miter,
    };
    let opacity = get_f(node, "stroke-opacity", 1.0);
    Some(Stroke { color, width, linecap: lc, linejoin: lj, miter_limit: 10.0, align: StrokeAlign::Center, dash_pattern: [0.0; 6], dash_len: 0, start_arrow: Arrowhead::None, end_arrow: Arrowhead::None, start_arrow_scale: 100.0, end_arrow_scale: 100.0, arrow_align: ArrowAlign::TipAtEnd, opacity })
}

fn parse_transform(node: &XmlNode) -> Option<Transform> {
    let val = node.attrs.get("transform")?;
    if val.starts_with("matrix(") {
        let inner = val.trim_start_matches("matrix(").trim_end_matches(')');
        let parts: Vec<f64> = inner.split([',', ' '])
            .filter(|s| !s.is_empty())
            .filter_map(|s| s.parse().ok())
            .collect();
        if parts.len() == 6 {
            return Some(Transform {
                a: parts[0], b: parts[1], c: parts[2], d: parts[3],
                e: pt(parts[4]), f: pt(parts[5]),
            });
        }
    }
    if val.starts_with("translate(") {
        let inner = val.trim_start_matches("translate(").trim_end_matches(')');
        let parts: Vec<f64> = inner.split([',', ' '])
            .filter(|s| !s.is_empty())
            .filter_map(|s| s.parse().ok())
            .collect();
        let tx = parts.first().copied().unwrap_or(0.0);
        let ty = parts.get(1).copied().unwrap_or(0.0);
        return Some(Transform::translate(pt(tx), pt(ty)));
    }
    if val.starts_with("rotate(") {
        let inner = val.trim_start_matches("rotate(").trim_end_matches(')');
        if let Ok(angle) = inner.trim().parse::<f64>() {
            return Some(Transform::rotate(angle));
        }
    }
    if val.starts_with("scale(") {
        let inner = val.trim_start_matches("scale(").trim_end_matches(')');
        let parts: Vec<f64> = inner.split([',', ' '])
            .filter(|s| !s.is_empty())
            .filter_map(|s| s.parse().ok())
            .collect();
        let sx = parts.first().copied().unwrap_or(1.0);
        let sy = parts.get(1).copied().unwrap_or(sx);
        return Some(Transform::scale(sx, sy));
    }
    None
}

fn parse_opacity(node: &XmlNode) -> f64 {
    get_f(node, "opacity", 1.0)
}

fn parse_common(node: &XmlNode) -> CommonProps {
    // `visibility` is runtime-only state — it is not preserved in
    // SVG, so it always loads as `Preview`. See SELECTION.md /
    // DOCUMENT.md for the rationale.
    CommonProps {
        opacity: parse_opacity(node),
        mode: crate::geometry::element::BlendMode::default(),
        transform: parse_transform(node),
        locked: false,
        visibility: crate::geometry::element::Visibility::default(),
    }
}

fn parse_points(s: &str) -> Vec<(f64, f64)> {
    let mut result = Vec::new();
    for pair in s.split_whitespace() {
        let parts: Vec<&str> = pair.split(',').collect();
        if parts.len() == 2
            && let (Ok(x), Ok(y)) = (parts[0].parse::<f64>(), parts[1].parse::<f64>()) {
                result.push((pt(x), pt(y)));
            }
    }
    result
}

// ---------------------------------------------------------------------------
// Path d-attribute tokenizer
// ---------------------------------------------------------------------------

fn parse_path_d(d: &str) -> Vec<PathCommand> {
    let mut commands = Vec::new();
    let tokens = tokenize_path(d);
    let mut i = 0;
    let mut cur_x = 0.0_f64;
    let mut cur_y = 0.0_f64;
    let mut start_x = 0.0_f64;
    let mut start_y = 0.0_f64;
    let mut cmd = ' ';

    let next_num = |i: &mut usize, tokens: &[PathToken]| -> f64 {
        while *i < tokens.len() {
            if let PathToken::Num(v) = tokens[*i] {
                *i += 1;
                return v;
            }
            *i += 1;
        }
        0.0
    };

    while i < tokens.len() {
        match &tokens[i] {
            PathToken::Cmd(c) => {
                cmd = *c;
                i += 1;
            }
            PathToken::Num(_) => {
                // implicit repeat of previous command
            }
        }

        match cmd {
            'Z' | 'z' => {
                commands.push(PathCommand::ClosePath);
                cur_x = start_x;
                cur_y = start_y;
            }
            'M' => {
                let x = next_num(&mut i, &tokens);
                let y = next_num(&mut i, &tokens);
                commands.push(PathCommand::MoveTo { x: pt(x), y: pt(y) });
                cur_x = x; cur_y = y;
                start_x = x; start_y = y;
                cmd = 'L'; // implicit lineto after moveto
            }
            'm' => {
                let x = cur_x + next_num(&mut i, &tokens);
                let y = cur_y + next_num(&mut i, &tokens);
                commands.push(PathCommand::MoveTo { x: pt(x), y: pt(y) });
                cur_x = x; cur_y = y;
                start_x = x; start_y = y;
                cmd = 'l';
            }
            'L' => {
                let x = next_num(&mut i, &tokens);
                let y = next_num(&mut i, &tokens);
                commands.push(PathCommand::LineTo { x: pt(x), y: pt(y) });
                cur_x = x; cur_y = y;
            }
            'l' => {
                let x = cur_x + next_num(&mut i, &tokens);
                let y = cur_y + next_num(&mut i, &tokens);
                commands.push(PathCommand::LineTo { x: pt(x), y: pt(y) });
                cur_x = x; cur_y = y;
            }
            'H' => {
                let x = next_num(&mut i, &tokens);
                commands.push(PathCommand::LineTo { x: pt(x), y: pt(cur_y) });
                cur_x = x;
            }
            'h' => {
                let x = cur_x + next_num(&mut i, &tokens);
                commands.push(PathCommand::LineTo { x: pt(x), y: pt(cur_y) });
                cur_x = x;
            }
            'V' => {
                let y = next_num(&mut i, &tokens);
                commands.push(PathCommand::LineTo { x: pt(cur_x), y: pt(y) });
                cur_y = y;
            }
            'v' => {
                let y = cur_y + next_num(&mut i, &tokens);
                commands.push(PathCommand::LineTo { x: pt(cur_x), y: pt(y) });
                cur_y = y;
            }
            'C' => {
                let x1 = next_num(&mut i, &tokens);
                let y1 = next_num(&mut i, &tokens);
                let x2 = next_num(&mut i, &tokens);
                let y2 = next_num(&mut i, &tokens);
                let x = next_num(&mut i, &tokens);
                let y = next_num(&mut i, &tokens);
                commands.push(PathCommand::CurveTo {
                    x1: pt(x1), y1: pt(y1), x2: pt(x2), y2: pt(y2), x: pt(x), y: pt(y),
                });
                cur_x = x; cur_y = y;
            }
            'c' => {
                let x1 = cur_x + next_num(&mut i, &tokens);
                let y1 = cur_y + next_num(&mut i, &tokens);
                let x2 = cur_x + next_num(&mut i, &tokens);
                let y2 = cur_y + next_num(&mut i, &tokens);
                let x = cur_x + next_num(&mut i, &tokens);
                let y = cur_y + next_num(&mut i, &tokens);
                commands.push(PathCommand::CurveTo {
                    x1: pt(x1), y1: pt(y1), x2: pt(x2), y2: pt(y2), x: pt(x), y: pt(y),
                });
                cur_x = x; cur_y = y;
            }
            'S' => {
                let x2 = next_num(&mut i, &tokens);
                let y2 = next_num(&mut i, &tokens);
                let x = next_num(&mut i, &tokens);
                let y = next_num(&mut i, &tokens);
                commands.push(PathCommand::SmoothCurveTo {
                    x2: pt(x2), y2: pt(y2), x: pt(x), y: pt(y),
                });
                cur_x = x; cur_y = y;
            }
            's' => {
                let x2 = cur_x + next_num(&mut i, &tokens);
                let y2 = cur_y + next_num(&mut i, &tokens);
                let x = cur_x + next_num(&mut i, &tokens);
                let y = cur_y + next_num(&mut i, &tokens);
                commands.push(PathCommand::SmoothCurveTo {
                    x2: pt(x2), y2: pt(y2), x: pt(x), y: pt(y),
                });
                cur_x = x; cur_y = y;
            }
            'Q' => {
                let x1 = next_num(&mut i, &tokens);
                let y1 = next_num(&mut i, &tokens);
                let x = next_num(&mut i, &tokens);
                let y = next_num(&mut i, &tokens);
                commands.push(PathCommand::QuadTo {
                    x1: pt(x1), y1: pt(y1), x: pt(x), y: pt(y),
                });
                cur_x = x; cur_y = y;
            }
            'q' => {
                let x1 = cur_x + next_num(&mut i, &tokens);
                let y1 = cur_y + next_num(&mut i, &tokens);
                let x = cur_x + next_num(&mut i, &tokens);
                let y = cur_y + next_num(&mut i, &tokens);
                commands.push(PathCommand::QuadTo {
                    x1: pt(x1), y1: pt(y1), x: pt(x), y: pt(y),
                });
                cur_x = x; cur_y = y;
            }
            'T' => {
                let x = next_num(&mut i, &tokens);
                let y = next_num(&mut i, &tokens);
                commands.push(PathCommand::SmoothQuadTo { x: pt(x), y: pt(y) });
                cur_x = x; cur_y = y;
            }
            't' => {
                let x = cur_x + next_num(&mut i, &tokens);
                let y = cur_y + next_num(&mut i, &tokens);
                commands.push(PathCommand::SmoothQuadTo { x: pt(x), y: pt(y) });
                cur_x = x; cur_y = y;
            }
            'A' => {
                let rx = next_num(&mut i, &tokens);
                let ry = next_num(&mut i, &tokens);
                let rotation = next_num(&mut i, &tokens);
                let large_arc = next_num(&mut i, &tokens) != 0.0;
                let sweep = next_num(&mut i, &tokens) != 0.0;
                let x = next_num(&mut i, &tokens);
                let y = next_num(&mut i, &tokens);
                commands.push(PathCommand::ArcTo {
                    rx: pt(rx), ry: pt(ry), x_rotation: rotation,
                    large_arc, sweep, x: pt(x), y: pt(y),
                });
                cur_x = x; cur_y = y;
            }
            'a' => {
                let rx = next_num(&mut i, &tokens);
                let ry = next_num(&mut i, &tokens);
                let rotation = next_num(&mut i, &tokens);
                let large_arc = next_num(&mut i, &tokens) != 0.0;
                let sweep = next_num(&mut i, &tokens) != 0.0;
                let x = cur_x + next_num(&mut i, &tokens);
                let y = cur_y + next_num(&mut i, &tokens);
                commands.push(PathCommand::ArcTo {
                    rx: pt(rx), ry: pt(ry), x_rotation: rotation,
                    large_arc, sweep, x: pt(x), y: pt(y),
                });
                cur_x = x; cur_y = y;
            }
            _ => { i += 1; }
        }
    }
    commands
}

#[derive(Debug)]
enum PathToken {
    Cmd(char),
    Num(f64),
}

fn tokenize_path(d: &str) -> Vec<PathToken> {
    let mut tokens = Vec::new();
    let mut chars = d.chars().peekable();
    while let Some(&c) = chars.peek() {
        if c.is_whitespace() || c == ',' {
            chars.next();
            continue;
        }
        if "MmLlHhVvCcSsQqTtAaZz".contains(c) {
            tokens.push(PathToken::Cmd(c));
            chars.next();
            continue;
        }
        // Number
        let mut num = String::new();
        if c == '-' || c == '+' {
            num.push(c);
            chars.next();
        }
        while let Some(&c) = chars.peek() {
            if c.is_ascii_digit() || c == '.' {
                num.push(c);
                chars.next();
            } else if (c == 'e' || c == 'E') && !num.is_empty() {
                num.push(c);
                chars.next();
                if let Some(&c2) = chars.peek()
                    && (c2 == '+' || c2 == '-') {
                        num.push(c2);
                        chars.next();
                    }
            } else {
                break;
            }
        }
        if !num.is_empty() {
            if let Ok(v) = num.parse::<f64>() {
                tokens.push(PathToken::Num(v));
            }
        } else {
            chars.next(); // skip unrecognized
        }
    }
    tokens
}

// ---------------------------------------------------------------------------
// Parse SVG element tree to Document elements
// ---------------------------------------------------------------------------

fn parse_element(node: &XmlNode) -> Option<Element> {
    let tag = strip_ns(&node.tag);
    let common = parse_common(node);

    match tag {
        "line" => Some(Element::Line(LineElem {
            x1: pt(get_f(node, "x1", 0.0)),
            y1: pt(get_f(node, "y1", 0.0)),
            x2: pt(get_f(node, "x2", 0.0)),
            y2: pt(get_f(node, "y2", 0.0)),
            stroke: parse_stroke(node),
            width_points: vec![],
            common,
        })),
        "rect" => Some(Element::Rect(RectElem {
            x: pt(get_f(node, "x", 0.0)),
            y: pt(get_f(node, "y", 0.0)),
            width: pt(get_f(node, "width", 0.0)),
            height: pt(get_f(node, "height", 0.0)),
            rx: pt(get_f(node, "rx", 0.0)),
            ry: pt(get_f(node, "ry", 0.0)),
            fill: parse_fill(node),
            stroke: parse_stroke(node),
            common,
        })),
        "circle" => Some(Element::Circle(CircleElem {
            cx: pt(get_f(node, "cx", 0.0)),
            cy: pt(get_f(node, "cy", 0.0)),
            r: pt(get_f(node, "r", 0.0)),
            fill: parse_fill(node),
            stroke: parse_stroke(node),
            common,
        })),
        "ellipse" => Some(Element::Ellipse(EllipseElem {
            cx: pt(get_f(node, "cx", 0.0)),
            cy: pt(get_f(node, "cy", 0.0)),
            rx: pt(get_f(node, "rx", 0.0)),
            ry: pt(get_f(node, "ry", 0.0)),
            fill: parse_fill(node),
            stroke: parse_stroke(node),
            common,
        })),
        "polyline" => {
            let pts = parse_points(get_s(node, "points", ""));
            Some(Element::Polyline(PolylineElem {
                points: pts,
                fill: parse_fill(node),
                stroke: parse_stroke(node),
                common,
            }))
        }
        "polygon" => {
            let pts = parse_points(get_s(node, "points", ""));
            Some(Element::Polygon(PolygonElem {
                points: pts,
                fill: parse_fill(node),
                stroke: parse_stroke(node),
                common,
            }))
        }
        "path" => {
            let d = parse_path_d(get_s(node, "d", ""));
            Some(Element::Path(PathElem {
                d,
                fill: parse_fill(node),
                stroke: parse_stroke(node),
                width_points: vec![],
                common,
            }))
        }
        "text" => {
            let ff = get_s(node, "font-family", "sans-serif").to_string();
            let fs = pt(get_f(node, "font-size", 16.0));
            let fw = get_s(node, "font-weight", "normal").to_string();
            let fst = get_s(node, "font-style", "normal").to_string();
            let td = get_s(node, "text-decoration", "none").to_string();
            let tt = get_s(node, "text-transform", "").to_string();
            let fv = get_s(node, "font-variant", "").to_string();
            let bs = get_s(node, "baseline-shift", "").to_string();
            let lh = get_s(node, "line-height", "").to_string();
            let ls = get_s(node, "letter-spacing", "").to_string();
            let lang = node.attrs.get("xml:lang")
                .or_else(|| node.attrs.get("lang"))
                .cloned()
                .unwrap_or_default();
            let aa = node.attrs.get("urn:jas:1:aa-mode")
                .cloned()
                .unwrap_or_default();
            let rotate = get_s(node, "rotate", "").to_string();
            let h_scale = get_s(node, "horizontal-scale", "").to_string();
            let v_scale = get_s(node, "vertical-scale", "").to_string();
            let kerning = node.attrs.get("urn:jas:1:kerning-mode")
                .cloned()
                .unwrap_or_default();

            // Check for textPath child
            for child in &node.children {
                let ctag = strip_ns(&child.tag);
                if ctag == "textPath" {
                    let d_str = child.attrs.get("path")
                        .or_else(|| child.attrs.get("d"))
                        .map(|s| s.as_str())
                        .unwrap_or("");
                    let d = parse_path_d(d_str);
                    let offset_str = get_s(child, "startOffset", "0");
                    let start_offset = if offset_str.ends_with('%') {
                        offset_str.trim_end_matches('%').parse::<f64>().unwrap_or(0.0) / 100.0
                    } else {
                        offset_str.parse::<f64>().unwrap_or(0.0)
                    };
                    // TextPath can host tspan children; if any are present,
                    // build the tspan list from them. Otherwise fall back to
                    // the child's flat text as a single default tspan.
                    let tp_tspan_children: Vec<&XmlNode> = child
                        .children
                        .iter()
                        .filter(|c| strip_ns(&c.tag) == "tspan")
                        .collect();
                    let tspans = if tp_tspan_children.is_empty() {
                        vec![crate::geometry::tspan::Tspan {
                            content: child.text.clone(),
                            ..crate::geometry::tspan::Tspan::default_tspan()
                        }]
                    } else {
                        tp_tspan_children
                            .iter()
                            .enumerate()
                            .flat_map(|(_, c)| parse_tspan(c))
                            .enumerate()
                            .map(|(idx, mut t)| { t.id = idx as u32; t })
                            .collect()
                    };
                    return Some(Element::TextPath(TextPathElem {
                        d,
                        tspans,
                        start_offset,
                        font_family: ff,
                        font_size: fs,
                        font_weight: fw,
                        font_style: fst,
                        text_decoration: td,
                        text_transform: tt.clone(),
                        font_variant: fv.clone(),
                        baseline_shift: bs.clone(),
                        line_height: lh.clone(),
                        letter_spacing: ls.clone(),
                        xml_lang: lang.clone(),
                        aa_mode: aa.clone(),
                        rotate: rotate.clone(),
                        horizontal_scale: h_scale.clone(),
                        vertical_scale: v_scale.clone(),
                        kerning: kerning.clone(),
                        fill: parse_fill(node),
                        stroke: parse_stroke(node),
                        common,
                    }));
                }
            }

            // Tspan children of a <text> element — if present, they are the
            // authoritative content; node.text (the inter-tspan whitespace
            // that XML collected into one field) is discarded.
            let text_tspan_children: Vec<&XmlNode> = node
                .children
                .iter()
                .filter(|c| strip_ns(&c.tag) == "tspan")
                .collect();
            let tspans: Vec<crate::geometry::tspan::Tspan> = if text_tspan_children.is_empty() {
                vec![crate::geometry::tspan::Tspan {
                    content: node.text.clone(),
                    ..crate::geometry::tspan::Tspan::default_tspan()
                }]
            } else {
                text_tspan_children
                    .iter()
                    .flat_map(|c| parse_tspan(c))
                    .enumerate()
                    .map(|(idx, mut t)| { t.id = idx as u32; t })
                    .collect()
            };
            let content: String = tspans.iter().map(|t| t.content.as_str()).collect();
            let mut tw = 0.0;
            if let Some(style) = node.attrs.get("style")
                && let Some(pos) = style.find("inline-size:") {
                    let rest = &style[pos + 12..];
                    let num_str: String = rest.trim_start().chars()
                        .take_while(|c| c.is_ascii_digit() || *c == '.')
                        .collect();
                    if let Ok(v) = num_str.parse::<f64>() {
                        tw = pt(v);
                    }
                }
            let th = if tw > 0.0 {
                let lines = (content.len() as f64 * fs * super::element::APPROX_CHAR_WIDTH_FACTOR / tw).ceil().max(1.0);
                lines * fs * 1.2
            } else { 0.0 };

            // SVG `y` is the baseline of the first line; convert it to
            // the layout-box top by subtracting the ascent (0.8 * fs).
            let svg_y = pt(get_f(node, "y", 0.0));
            Some(Element::Text(TextElem {
                x: pt(get_f(node, "x", 0.0)),
                y: svg_y - fs * 0.8,
                tspans,
                font_family: ff,
                font_size: fs,
                font_weight: fw,
                font_style: fst,
                text_decoration: td,
                text_transform: tt,
                font_variant: fv,
                baseline_shift: bs,
                line_height: lh,
                letter_spacing: ls,
                xml_lang: lang,
                aa_mode: aa,
                rotate,
                horizontal_scale: h_scale,
                vertical_scale: v_scale,
                kerning,
                width: tw,
                height: th,
                fill: parse_fill(node),
                stroke: parse_stroke(node),
                common,
            }))
        }
        "g" => {
            let mut children = Vec::new();
            for child in &node.children {
                if let Some(elem) = parse_element(child) {
                    children.push(Rc::new(elem));
                }
            }
            // Check for inkscape:label
            let label = node.attrs.get("inkscape:label")
                .cloned();
            if let Some(name) = label {
                Some(Element::Layer(LayerElem { children, name, common, isolated_blending: false, knockout_group: false }))
            } else {
                Some(Element::Group(GroupElem { children, common, isolated_blending: false, knockout_group: false }))
            }
        }
        _ => None,
    }
}

/// Parse an SVG string and return a Document.
pub fn svg_to_document(svg: &str) -> Document {
    let root = match parse_xml(svg) {
        Some(r) => r,
        None => return Document::default(),
    };
    let mut layers: Vec<Element> = Vec::new();
    for child in &root.children {
        let elem = match parse_element(child) {
            Some(e) => e,
            None => continue,
        };
        match &elem {
            Element::Layer(_) => {
                layers.push(elem);
            }
            Element::Group(g) => {
                // Promote top-level groups to layers
                layers.push(Element::Layer(LayerElem {
                    children: g.children.clone(),
                    name: String::new(),
                    common: g.common.clone(),
                    isolated_blending: g.isolated_blending,
                    knockout_group: g.knockout_group,
                }));
            }
            _ => {
                // Wrap standalone elements in a default layer
                if layers.is_empty() || !layers.last().is_some_and(|l| {
                    if let Element::Layer(le) = l { le.name.is_empty() } else { false }
                }) {
                    layers.push(Element::Layer(LayerElem {
                        children: vec![Rc::new(elem)],
                        name: String::new(),
                        common: CommonProps::default(),
                        isolated_blending: false,
                        knockout_group: false,
                    }));
                } else if let Some(Element::Layer(le)) = layers.last_mut() {
                    le.children.push(Rc::new(elem));
                }
            }
        }
    }
    // SVG has no artboards concept. Parsed SVG documents produce
    // an empty artboards list; native loaders enforce the
    // at-least-one invariant at app load time. See
    // ARTBOARDS.md §At-least-one-artboard invariant for the
    // load-time repair contract.
    if layers.is_empty() {
        let mut d = Document::default();
        d.artboards = Vec::new();
        d.artboard_options = crate::document::artboard::ArtboardOptions::default();
        return d;
    }
    let doc = Document {
        layers,
        selected_layer: 0,
        selection: Vec::new(),
        artboards: Vec::new(),
        artboard_options: crate::document::artboard::ArtboardOptions::default(),
    };
    normalize_document(&doc)
}

// ---------------------------------------------------------------------------
// Named colors
// ---------------------------------------------------------------------------

fn named_colors_map() -> HashMap<&'static str, (u8, u8, u8)> {
    let mut m = HashMap::new();
    m.insert("black", (0, 0, 0));
    m.insert("white", (255, 255, 255));
    m.insert("red", (255, 0, 0));
    m.insert("green", (0, 128, 0));
    m.insert("blue", (0, 0, 255));
    m.insert("yellow", (255, 255, 0));
    m.insert("cyan", (0, 255, 255));
    m.insert("magenta", (255, 0, 255));
    m.insert("gray", (128, 128, 128));
    m.insert("grey", (128, 128, 128));
    m.insert("silver", (192, 192, 192));
    m.insert("maroon", (128, 0, 0));
    m.insert("olive", (128, 128, 0));
    m.insert("lime", (0, 255, 0));
    m.insert("aqua", (0, 255, 255));
    m.insert("teal", (0, 128, 128));
    m.insert("navy", (0, 0, 128));
    m.insert("fuchsia", (255, 0, 255));
    m.insert("purple", (128, 0, 128));
    m.insert("orange", (255, 165, 0));
    m.insert("pink", (255, 192, 203));
    m.insert("brown", (165, 42, 42));
    m.insert("coral", (255, 127, 80));
    m.insert("crimson", (220, 20, 60));
    m.insert("gold", (255, 215, 0));
    m.insert("indigo", (75, 0, 130));
    m.insert("ivory", (255, 255, 240));
    m.insert("khaki", (240, 230, 140));
    m.insert("lavender", (230, 230, 250));
    m.insert("plum", (221, 160, 221));
    m.insert("salmon", (250, 128, 114));
    m.insert("sienna", (160, 82, 45));
    m.insert("tan", (210, 180, 140));
    m.insert("tomato", (255, 99, 71));
    m.insert("turquoise", (64, 224, 208));
    m.insert("violet", (238, 130, 238));
    m.insert("wheat", (245, 222, 179));
    m.insert("steelblue", (70, 130, 180));
    m.insert("skyblue", (135, 206, 235));
    m.insert("slategray", (112, 128, 144));
    m.insert("slategrey", (112, 128, 144));
    m.insert("darkgray", (169, 169, 169));
    m.insert("darkgrey", (169, 169, 169));
    m.insert("lightgray", (211, 211, 211));
    m.insert("lightgrey", (211, 211, 211));
    m.insert("darkblue", (0, 0, 139));
    m.insert("darkgreen", (0, 100, 0));
    m.insert("darkred", (139, 0, 0));
    m
}

use std::sync::OnceLock;

static NAMED_COLORS: OnceLock<HashMap<&'static str, (u8, u8, u8)>> = OnceLock::new();

fn get_named_colors() -> &'static HashMap<&'static str, (u8, u8, u8)> {
    NAMED_COLORS.get_or_init(named_colors_map)
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::geometry::element::*;

    fn make_rect(x: f64, y: f64, w: f64, h: f64) -> Element {
        Element::Rect(RectElem {
            x, y, width: w, height: h, rx: 0.0, ry: 0.0,
            fill: Some(Fill::new(Color::rgb(1.0, 0.0, 0.0))),
            stroke: None, common: CommonProps::default(),
        })
    }

    fn make_line(x1: f64, y1: f64, x2: f64, y2: f64) -> Element {
        Element::Line(LineElem {
            x1, y1, x2, y2,
            stroke: Some(Stroke::new(Color::BLACK, 1.0)),
            width_points: Vec::new(),
            common: CommonProps::default(),
        })
    }

    fn make_circle(cx: f64, cy: f64, r: f64) -> Element {
        Element::Circle(CircleElem {
            cx, cy, r,
            fill: Some(Fill::new(Color::rgb(0.0, 0.0, 1.0))),
            stroke: None, common: CommonProps::default(),
        })
    }

    fn make_doc(children: Vec<Element>) -> Document {
        Document {
            layers: vec![Element::Layer(LayerElem {
                name: "Layer".to_string(),
                children: children.into_iter().map(Rc::new).collect(),
                isolated_blending: false,
                knockout_group: false,
                common: CommonProps::default(),
            })],
            selected_layer: 0,
            selection: vec![],
            ..Document::default()
        }
    }

    #[test]
    fn export_empty_document() {
        let doc = Document::default();
        let svg = document_to_svg(&doc);
        assert!(svg.contains("<svg"));
        assert!(svg.contains("</svg>"));
    }

    #[test]
    fn export_contains_rect() {
        let doc = make_doc(vec![make_rect(10.0, 20.0, 30.0, 40.0)]);
        let svg = document_to_svg(&doc);
        assert!(svg.contains("<rect"));
    }

    #[test]
    fn export_contains_line() {
        let doc = make_doc(vec![make_line(0.0, 0.0, 50.0, 50.0)]);
        let svg = document_to_svg(&doc);
        assert!(svg.contains("<line"));
    }

    #[test]
    fn export_contains_circle() {
        let doc = make_doc(vec![make_circle(50.0, 50.0, 20.0)]);
        let svg = document_to_svg(&doc);
        assert!(svg.contains("<circle"));
    }

    #[test]
    fn export_rounded_rect_has_rx_ry() {
        let doc = make_doc(vec![Element::Rect(RectElem {
            x: 10.0, y: 20.0, width: 100.0, height: 50.0,
            rx: 10.0, ry: 10.0,
            fill: Some(Fill::new(Color::WHITE)),
            stroke: Some(Stroke::new(Color::BLACK, 1.0)),
            common: CommonProps::default(),
        })]);
        let svg = document_to_svg(&doc);
        assert!(svg.contains("rx=\""), "expected rx attribute in: {svg}");
        assert!(svg.contains("ry=\""), "expected ry attribute in: {svg}");
    }

    #[test]
    fn export_plain_rect_omits_rx_ry() {
        let doc = make_doc(vec![make_rect(10.0, 20.0, 30.0, 40.0)]);
        let svg = document_to_svg(&doc);
        assert!(!svg.contains("rx=\""), "plain rect should not emit rx: {svg}");
        assert!(!svg.contains("ry=\""), "plain rect should not emit ry: {svg}");
    }

    #[test]
    fn roundtrip_rounded_rect_preserves_rx_ry() {
        let doc = make_doc(vec![Element::Rect(RectElem {
            x: 10.0, y: 20.0, width: 100.0, height: 50.0,
            rx: 10.0, ry: 10.0,
            fill: Some(Fill::new(Color::WHITE)),
            stroke: Some(Stroke::new(Color::BLACK, 1.0)),
            common: CommonProps::default(),
        })]);
        let svg = document_to_svg(&doc);
        let doc2 = svg_to_document(&svg);
        let children = doc2.layers[0].children().unwrap();
        assert_eq!(children.len(), 1);
        if let Element::Rect(r) = &*children[0] {
            assert!(r.rx > 0.0, "expected rx > 0 after roundtrip, got {}", r.rx);
            assert!(r.ry > 0.0, "expected ry > 0 after roundtrip, got {}", r.ry);
        } else {
            panic!("expected Rect, got {:?}", &*children[0]);
        }
    }

    #[test]
    fn roundtrip_rect() {
        let doc = make_doc(vec![make_rect(10.0, 20.0, 30.0, 40.0)]);
        let svg = document_to_svg(&doc);
        let doc2 = svg_to_document(&svg);
        let children = doc2.layers[0].children().unwrap();
        assert_eq!(children.len(), 1);
        if let Element::Rect(r) = &*children[0] {
            // SVG uses pt-to-px conversion (96/72), check approximately
            assert!(r.width > 0.0);
            assert!(r.height > 0.0);
        } else {
            panic!("expected Rect, got {:?}", &*children[0]);
        }
    }

    #[test]
    fn roundtrip_line() {
        let doc = make_doc(vec![make_line(0.0, 0.0, 100.0, 100.0)]);
        let svg = document_to_svg(&doc);
        let doc2 = svg_to_document(&svg);
        let children = doc2.layers[0].children().unwrap();
        assert_eq!(children.len(), 1);
        assert!(matches!(&*children[0], Element::Line(_)));
    }

    #[test]
    fn roundtrip_circle() {
        let doc = make_doc(vec![make_circle(50.0, 50.0, 20.0)]);
        let svg = document_to_svg(&doc);
        let doc2 = svg_to_document(&svg);
        let children = doc2.layers[0].children().unwrap();
        assert_eq!(children.len(), 1);
        assert!(matches!(&*children[0], Element::Circle(_)));
    }

    #[test]
    fn roundtrip_multiple_elements() {
        let doc = make_doc(vec![
            make_rect(0.0, 0.0, 10.0, 10.0),
            make_line(0.0, 0.0, 50.0, 50.0),
            make_circle(30.0, 30.0, 15.0),
        ]);
        let svg = document_to_svg(&doc);
        let doc2 = svg_to_document(&svg);
        let children = doc2.layers[0].children().unwrap();
        assert_eq!(children.len(), 3);
    }

    #[test]
    fn roundtrip_group() {
        let g = Element::Group(GroupElem {
            children: vec![Rc::new(make_rect(0.0, 0.0, 10.0, 10.0)), Rc::new(make_line(0.0, 0.0, 5.0, 5.0))],
            isolated_blending: false,
            knockout_group: false,
            common: CommonProps::default(),
        });
        let doc = make_doc(vec![g]);
        let svg = document_to_svg(&doc);
        let doc2 = svg_to_document(&svg);
        let children = doc2.layers[0].children().unwrap();
        assert_eq!(children.len(), 1);
        assert!(matches!(&*children[0], Element::Group(_)));
        let group_children = children[0].children().unwrap();
        assert_eq!(group_children.len(), 2);
    }

    #[test]
    fn roundtrip_text_preserves_y_as_top() {
        // Internally `e.y` is the top of the layout box. Round-tripping
        // through SVG (which uses the baseline as `y`) must put us back
        // at the same top-of-box position.
        let t = TextElem::from_string(
            10.0, 20.0, "Hi",
            "sans-serif", 16.0,
            "normal", "normal", "none",
            0.0, 0.0,
            Some(Fill::new(Color::BLACK)), None,
            CommonProps::default(),
        );
        let doc = make_doc(vec![Element::Text(t)]);
        let svg = document_to_svg(&doc);
        let doc2 = svg_to_document(&svg);
        let children = doc2.layers[0].children().unwrap();
        if let Element::Text(t2) = &*children[0] {
            assert!((t2.y - 20.0).abs() < 1e-3, "got y = {}", t2.y);
            assert!((t2.x - 10.0).abs() < 1e-3, "got x = {}", t2.x);
        } else {
            panic!("expected Text");
        }
        assert!(svg.contains("<text"));
    }

    #[test]
    fn import_minimal_svg() {
        let svg = r#"<svg xmlns="http://www.w3.org/2000/svg"><rect x="10" y="20" width="30" height="40"/></svg>"#;
        let doc = svg_to_document(svg);
        assert!(!doc.layers.is_empty());
        let children = doc.layers[0].children().unwrap();
        assert_eq!(children.len(), 1);
        assert!(matches!(&*children[0], Element::Rect(_)));
    }

    #[test]
    fn import_svg_with_fill() {
        let svg = r#"<svg xmlns="http://www.w3.org/2000/svg"><rect x="0" y="0" width="10" height="10" fill="red"/></svg>"#;
        let doc = svg_to_document(svg);
        let children = doc.layers[0].children().unwrap();
        if let Element::Rect(r) = &*children[0] {
            assert!(r.fill.is_some());
            let c = r.fill.unwrap().color;
            let (rv, _, _, _) = c.to_rgba();
            assert!((rv - 1.0).abs() < 0.01);
        }
    }

    #[test]
    fn import_empty_svg() {
        let svg = r#"<svg xmlns="http://www.w3.org/2000/svg"></svg>"#;
        let doc = svg_to_document(svg);
        assert!(!doc.layers.is_empty());
    }

    // -----------------------------------------------------------------------
    // Hex color parsing (4-digit and 8-digit)
    // -----------------------------------------------------------------------

    #[test]
    fn parse_color_4_digit_hex() {
        let c = parse_color("#F00A").unwrap();
        let (r, g, b, a) = c.to_rgba();
        assert!((r - 1.0).abs() < 0.01, "r={r}");
        assert!((g - 0.0).abs() < 0.01, "g={g}");
        assert!((b - 0.0).abs() < 0.01, "b={b}");
        // 0xAA / 255 ≈ 0.667
        assert!((a - 0.667).abs() < 0.01, "a={a}");
    }

    #[test]
    fn parse_color_8_digit_hex() {
        let c = parse_color("#FF000080").unwrap();
        let (r, g, b, a) = c.to_rgba();
        assert!((r - 1.0).abs() < 0.01, "r={r}");
        assert!((g - 0.0).abs() < 0.01, "g={g}");
        assert!((b - 0.0).abs() < 0.01, "b={b}");
        // 0x80 / 255 ≈ 0.502
        assert!((a - 0.502).abs() < 0.01, "a={a}");
    }

    // -----------------------------------------------------------------------
    // fill-opacity / stroke-opacity parsing
    // -----------------------------------------------------------------------

    #[test]
    fn import_fill_opacity() {
        let svg = r#"<svg xmlns="http://www.w3.org/2000/svg"><rect x="0" y="0" width="10" height="10" fill="red" fill-opacity="0.5"/></svg>"#;
        let doc = svg_to_document(svg);
        let children = doc.layers[0].children().unwrap();
        if let Element::Rect(r) = &*children[0] {
            // After normalization, fill.opacity should be 0.5 (color was opaque)
            assert!((r.fill.unwrap().opacity - 0.5).abs() < 0.01);
        } else {
            panic!("expected Rect");
        }
    }

    #[test]
    fn import_stroke_opacity() {
        let svg = r#"<svg xmlns="http://www.w3.org/2000/svg"><rect x="0" y="0" width="10" height="10" stroke="blue" stroke-width="2" stroke-opacity="0.3"/></svg>"#;
        let doc = svg_to_document(svg);
        let children = doc.layers[0].children().unwrap();
        if let Element::Rect(r) = &*children[0] {
            assert!((r.stroke.unwrap().opacity - 0.3).abs() < 0.01);
        } else {
            panic!("expected Rect");
        }
    }

    // -----------------------------------------------------------------------
    // fill-opacity / stroke-opacity export
    // -----------------------------------------------------------------------

    #[test]
    fn export_fill_opacity() {
        let doc = make_doc(vec![Element::Rect(RectElem {
            x: 0.0, y: 0.0, width: 10.0, height: 10.0, rx: 0.0, ry: 0.0,
            fill: Some(Fill { color: Color::rgb(1.0, 0.0, 0.0), opacity: 0.5 }),
            stroke: None, common: CommonProps::default(),
        })]);
        let svg = document_to_svg(&doc);
        assert!(svg.contains("fill-opacity=\"0.5\""), "svg={svg}");
    }

    #[test]
    fn export_stroke_opacity() {
        let doc = make_doc(vec![Element::Rect(RectElem {
            x: 0.0, y: 0.0, width: 10.0, height: 10.0, rx: 0.0, ry: 0.0,
            fill: None,
            stroke: Some(Stroke { opacity: 0.4, ..Stroke::new(Color::BLACK, 1.0) }),
            common: CommonProps::default(),
        })]);
        let svg = document_to_svg(&doc);
        assert!(svg.contains("stroke-opacity=\"0.4\""), "svg={svg}");
    }

    #[test]
    fn export_omits_opacity_when_one() {
        let doc = make_doc(vec![make_rect(0.0, 0.0, 10.0, 10.0)]);
        let svg = document_to_svg(&doc);
        assert!(!svg.contains("fill-opacity"), "svg={svg}");
        assert!(!svg.contains("stroke-opacity"), "svg={svg}");
    }

    // -----------------------------------------------------------------------
    // Normalizer
    // -----------------------------------------------------------------------

    #[test]
    fn normalize_extracts_fill_alpha() {
        use crate::geometry::normalize::normalize_document;
        let doc = make_doc(vec![Element::Rect(RectElem {
            x: 0.0, y: 0.0, width: 10.0, height: 10.0, rx: 0.0, ry: 0.0,
            fill: Some(Fill { color: Color::new(1.0, 0.0, 0.0, 0.5), opacity: 1.0 }),
            stroke: None, common: CommonProps::default(),
        })]);
        let doc2 = normalize_document(&doc);
        let children = doc2.layers[0].children().unwrap();
        if let Element::Rect(r) = &*children[0] {
            let f = r.fill.unwrap();
            assert!((f.opacity - 0.5).abs() < 1e-9, "fill opacity={}", f.opacity);
            assert!((f.color.alpha() - 1.0).abs() < 1e-9, "color alpha={}", f.color.alpha());
        } else {
            panic!("expected Rect");
        }
    }

    #[test]
    fn normalize_multiplies_existing() {
        use crate::geometry::normalize::normalize_document;
        let doc = make_doc(vec![Element::Rect(RectElem {
            x: 0.0, y: 0.0, width: 10.0, height: 10.0, rx: 0.0, ry: 0.0,
            fill: Some(Fill { color: Color::new(1.0, 0.0, 0.0, 0.5), opacity: 0.8 }),
            stroke: None, common: CommonProps::default(),
        })]);
        let doc2 = normalize_document(&doc);
        let children = doc2.layers[0].children().unwrap();
        if let Element::Rect(r) = &*children[0] {
            let f = r.fill.unwrap();
            assert!((f.opacity - 0.4).abs() < 1e-9, "fill opacity={}", f.opacity);
            assert!((f.color.alpha() - 1.0).abs() < 1e-9);
        } else {
            panic!("expected Rect");
        }
    }

    #[test]
    fn normalize_stroke_alpha() {
        use crate::geometry::normalize::normalize_document;
        let doc = make_doc(vec![Element::Line(LineElem {
            x1: 0.0, y1: 0.0, x2: 10.0, y2: 10.0,
            stroke: Some(Stroke::new(Color::new(0.0, 0.0, 0.0, 0.25), 1.0)),
            width_points: Vec::new(),
            common: CommonProps::default(),
        })]);
        let doc2 = normalize_document(&doc);
        let children = doc2.layers[0].children().unwrap();
        if let Element::Line(e) = &*children[0] {
            let s = e.stroke.unwrap();
            assert!((s.opacity - 0.25).abs() < 1e-9, "stroke opacity={}", s.opacity);
            assert!((s.color.alpha() - 1.0).abs() < 1e-9);
        } else {
            panic!("expected Line");
        }
    }

    #[test]
    fn normalize_no_fill_unchanged() {
        use crate::geometry::normalize::normalize_document;
        let doc = make_doc(vec![make_line(0.0, 0.0, 10.0, 10.0)]);
        let doc2 = normalize_document(&doc);
        let children = doc2.layers[0].children().unwrap();
        if let Element::Line(e) = &*children[0] {
            assert!(e.stroke.is_some());
            assert!((e.stroke.unwrap().opacity - 1.0).abs() < 1e-9);
        } else {
            panic!("expected Line");
        }
    }

    #[test]
    fn normalize_recursive() {
        use crate::geometry::normalize::normalize_document;
        let inner = Element::Rect(RectElem {
            x: 0.0, y: 0.0, width: 10.0, height: 10.0, rx: 0.0, ry: 0.0,
            fill: Some(Fill { color: Color::new(1.0, 0.0, 0.0, 0.5), opacity: 1.0 }),
            stroke: None, common: CommonProps::default(),
        });
        let group = Element::Group(GroupElem {
            children: vec![Rc::new(inner)],
            isolated_blending: false,
            knockout_group: false,
            common: CommonProps::default(),
        });
        let doc = make_doc(vec![group]);
        let doc2 = normalize_document(&doc);
        let layers = doc2.layers[0].children().unwrap();
        let group_children = layers[0].children().unwrap();
        if let Element::Rect(r) = &*group_children[0] {
            let f = r.fill.unwrap();
            assert!((f.opacity - 0.5).abs() < 1e-9);
            assert!((f.color.alpha() - 1.0).abs() < 1e-9);
        } else {
            panic!("expected Rect inside group");
        }
    }

    #[test]
    fn normalize_idempotent() {
        use crate::geometry::normalize::normalize_document;
        let doc = make_doc(vec![Element::Rect(RectElem {
            x: 0.0, y: 0.0, width: 10.0, height: 10.0, rx: 0.0, ry: 0.0,
            fill: Some(Fill { color: Color::new(1.0, 0.0, 0.0, 0.5), opacity: 0.8 }),
            stroke: None, common: CommonProps::default(),
        })]);
        let doc2 = normalize_document(&doc);
        let doc3 = normalize_document(&doc2);
        let c2 = doc2.layers[0].children().unwrap();
        let c3 = doc3.layers[0].children().unwrap();
        if let (Element::Rect(r2), Element::Rect(r3)) = (&*c2[0], &*c3[0]) {
            let f2 = r2.fill.unwrap();
            let f3 = r3.fill.unwrap();
            assert!((f2.opacity - f3.opacity).abs() < 1e-9);
            assert!((f2.color.alpha() - f3.color.alpha()).abs() < 1e-9);
        }
    }

    #[test]
    fn roundtrip_fill_opacity() {
        let doc = make_doc(vec![Element::Rect(RectElem {
            x: 10.0, y: 20.0, width: 30.0, height: 40.0, rx: 0.0, ry: 0.0,
            fill: Some(Fill { color: Color::rgb(1.0, 0.0, 0.0), opacity: 0.5 }),
            stroke: None, common: CommonProps::default(),
        })]);
        let svg = document_to_svg(&doc);
        let doc2 = svg_to_document(&svg);
        let children = doc2.layers[0].children().unwrap();
        if let Element::Rect(r) = &*children[0] {
            assert!((r.fill.unwrap().opacity - 0.5).abs() < 0.01, "opacity={}", r.fill.unwrap().opacity);
        } else {
            panic!("expected Rect");
        }
    }

    // ── tspan rotate roundtrip ───────────────────────────────────────

    /// Build a minimal SVG string of the form produced by our writer,
    /// wrapping a single `<text>` with the given tspan children.
    fn tspan_svg_doc(tspan_markup: &str) -> String {
        format!(
            r#"<?xml version="1.0" encoding="UTF-8"?><svg xmlns="http://www.w3.org/2000/svg" width="100" height="100"><text x="0" y="20" font-size="12">{}</text></svg>"#,
            tspan_markup
        )
    }

    #[test]
    fn tspan_svg_emits_rotate_attribute() {
        use crate::geometry::tspan::Tspan;
        let t = Tspan { content: "X".into(), rotate: Some(45.0),
                        ..Tspan::default_tspan() };
        let svg = tspan_svg(&t);
        assert!(svg.contains(r#"rotate="45""#), "got: {}", svg);
    }

    #[test]
    fn svg_single_value_rotate_roundtrips() {
        let svg = tspan_svg_doc(r#"<tspan rotate="30">abc</tspan>"#);
        let doc = svg_to_document(&svg);
        let children = doc.layers[0].children().unwrap();
        let Element::Text(t) = &*children[0] else { panic!("expected Text"); };
        assert_eq!(t.tspans.len(), 1);
        assert_eq!(t.tspans[0].content, "abc");
        assert_eq!(t.tspans[0].rotate, Some(30.0));
    }

    #[test]
    fn svg_multi_value_rotate_splits_into_per_glyph_tspans() {
        // rotate="a b c" on a 3-char tspan → three tspans, each
        // carrying one glyph and its own rotate angle.
        let svg = tspan_svg_doc(r#"<tspan rotate="45 90 0">abc</tspan>"#);
        let doc = svg_to_document(&svg);
        let children = doc.layers[0].children().unwrap();
        let Element::Text(t) = &*children[0] else { panic!("expected Text"); };
        assert_eq!(t.tspans.len(), 3);
        assert_eq!(t.tspans[0].content, "a");
        assert_eq!(t.tspans[0].rotate, Some(45.0));
        assert_eq!(t.tspans[1].content, "b");
        assert_eq!(t.tspans[1].rotate, Some(90.0));
        assert_eq!(t.tspans[2].content, "c");
        assert_eq!(t.tspans[2].rotate, Some(0.0));
    }

    #[test]
    fn svg_multi_value_rotate_reuses_last_for_extra_glyphs() {
        // SVG spec: "rotate" with fewer values than glyphs reuses
        // the last value for the remainder.
        let svg = tspan_svg_doc(r#"<tspan rotate="45 90">abcd</tspan>"#);
        let doc = svg_to_document(&svg);
        let children = doc.layers[0].children().unwrap();
        let Element::Text(t) = &*children[0] else { panic!("expected Text"); };
        assert_eq!(t.tspans.len(), 4);
        assert_eq!(t.tspans[0].rotate, Some(45.0));
        assert_eq!(t.tspans[1].rotate, Some(90.0));
        assert_eq!(t.tspans[2].rotate, Some(90.0));
        assert_eq!(t.tspans[3].rotate, Some(90.0));
    }

    #[test]
    fn svg_phase1b1_attrs_round_trip_through_document() {
        // Phase 1b1: a wrapper tspan carrying the 5 remaining
        // panel-surface paragraph attrs round-trips through the
        // document SVG: text-align, text-align-last, text-indent
        // (signed), jas:space-before, jas:space-after.
        use crate::geometry::tspan::Tspan;
        let mut doc = Document::default();
        let mut t = crate::tools::text_edit::empty_text_elem(10.0, 20.0, 0.0, 0.0);
        let mut wrapper = Tspan::default_tspan();
        wrapper.id = 0;
        wrapper.jas_role = Some("paragraph".into());
        wrapper.text_align = Some("justify".into());
        wrapper.text_align_last = Some("left".into());
        wrapper.text_indent = Some(-18.0);
        wrapper.jas_space_before = Some(6.0);
        wrapper.jas_space_after = Some(12.0);
        t.tspans = vec![
            wrapper,
            Tspan { id: 1, content: "hello".into(), ..Tspan::default_tspan() },
        ];
        doc.layers[0].children_mut().unwrap()
            .push(std::rc::Rc::new(Element::Text(t)));
        let svg = document_to_svg(&doc);
        assert!(svg.contains(r#"text-align="justify""#),
                "expected text-align in serialised SVG, got: {}", svg);
        assert!(svg.contains(r#"text-align-last="left""#));
        assert!(svg.contains(r#"text-indent="-18""#));
        assert!(svg.contains(r#"urn:jas:1:space-before="6""#));
        assert!(svg.contains(r#"urn:jas:1:space-after="12""#));
        let doc2 = svg_to_document(&svg);
        let children = doc2.layers[0].children().unwrap();
        let Element::Text(t) = &*children[0] else { panic!("expected Text"); };
        let w = &t.tspans[0];
        assert_eq!(w.text_align.as_deref(), Some("justify"));
        assert_eq!(w.text_align_last.as_deref(), Some("left"));
        assert_eq!(w.text_indent, Some(-18.0));
        assert_eq!(w.jas_space_before, Some(6.0));
        assert_eq!(w.jas_space_after, Some(12.0));
    }

    #[test]
    fn svg_phase3b_attrs_round_trip_through_document() {
        // Phase 3b: a wrapper tspan carrying the 5 panel-surface
        // paragraph attrs round-trips through the document SVG.
        use crate::geometry::tspan::Tspan;
        let mut doc = Document::default();
        let mut t = crate::tools::text_edit::empty_text_elem(10.0, 20.0, 0.0, 0.0);
        let mut wrapper = Tspan::default_tspan();
        wrapper.id = 0;
        wrapper.jas_role = Some("paragraph".into());
        wrapper.jas_left_indent = Some(18.0);
        wrapper.jas_right_indent = Some(9.0);
        wrapper.jas_hyphenate = Some(true);
        wrapper.jas_hanging_punctuation = Some(true);
        wrapper.jas_list_style = Some("num-decimal".into());
        t.tspans = vec![
            wrapper,
            Tspan { id: 1, content: "hello".into(), ..Tspan::default_tspan() },
        ];
        doc.layers[0].children_mut().unwrap()
            .push(std::rc::Rc::new(Element::Text(t)));
        let svg = document_to_svg(&doc);
        assert!(svg.contains(r#"urn:jas:1:left-indent="18""#),
                "expected left-indent in serialised SVG, got: {}", svg);
        assert!(svg.contains(r#"urn:jas:1:right-indent="9""#));
        assert!(svg.contains(r#"urn:jas:1:hyphenate="true""#));
        assert!(svg.contains(r#"urn:jas:1:hanging-punctuation="true""#));
        assert!(svg.contains(r#"urn:jas:1:list-style="num-decimal""#));
        let doc2 = svg_to_document(&svg);
        let children = doc2.layers[0].children().unwrap();
        let Element::Text(t) = &*children[0] else { panic!("expected Text"); };
        assert_eq!(t.tspans.len(), 2);
        let w = &t.tspans[0];
        assert_eq!(w.jas_role.as_deref(), Some("paragraph"));
        assert_eq!(w.jas_left_indent, Some(18.0));
        assert_eq!(w.jas_right_indent, Some(9.0));
        assert_eq!(w.jas_hyphenate, Some(true));
        assert_eq!(w.jas_hanging_punctuation, Some(true));
        assert_eq!(w.jas_list_style.as_deref(), Some("num-decimal"));
    }

    #[test]
    fn svg_jas_role_paragraph_roundtrips_through_document() {
        // Phase 1a: a <tspan urn:jas:1:role="paragraph"> in document SVG
        // parses with jas_role=Some("paragraph") and serialises back
        // with the role attribute preserved.
        use crate::geometry::tspan::Tspan;
        let mut doc = Document::default();
        let mut t = crate::tools::text_edit::empty_text_elem(10.0, 20.0, 0.0, 0.0);
        t.tspans = vec![
            Tspan {
                id: 0,
                jas_role: Some("paragraph".into()),
                ..Tspan::default_tspan()
            },
            Tspan {
                id: 1,
                content: "hello".into(),
                ..Tspan::default_tspan()
            },
        ];
        doc.layers[0].children_mut().unwrap()
            .push(std::rc::Rc::new(Element::Text(t)));
        let svg = document_to_svg(&doc);
        assert!(svg.contains(r#"urn:jas:1:role="paragraph""#),
                "expected urn:jas:1:role in serialised SVG, got: {}", svg);
        let doc2 = svg_to_document(&svg);
        let children = doc2.layers[0].children().unwrap();
        let Element::Text(t) = &*children[0] else { panic!("expected Text"); };
        // The wrapper tspan and the content tspan both round-trip.
        assert_eq!(t.tspans.len(), 2);
        assert_eq!(t.tspans[0].jas_role.as_deref(), Some("paragraph"));
        assert!(t.tspans[1].jas_role.is_none());
        assert_eq!(t.tspans[1].content, "hello");
    }

    #[test]
    fn svg_per_glyph_tspan_rotate_roundtrip() {
        // Build a doc with three per-glyph tspans and verify the
        // emitted SVG preserves each rotate value (emits separate
        // <tspan rotate="N">x</tspan> elements).
        let mut doc = Document::default();
        let mut t = crate::tools::text_edit::empty_text_elem(10.0, 20.0, 0.0, 0.0);
        use crate::geometry::tspan::Tspan;
        t.tspans = vec![
            Tspan { id: 0, content: "a".into(), rotate: Some(45.0),
                    ..Tspan::default_tspan() },
            Tspan { id: 1, content: "b".into(), rotate: Some(90.0),
                    ..Tspan::default_tspan() },
            Tspan { id: 2, content: "c".into(), rotate: Some(0.0),
                    ..Tspan::default_tspan() },
        ];
        doc.layers[0].children_mut().unwrap()
            .push(std::rc::Rc::new(Element::Text(t)));
        let svg = document_to_svg(&doc);
        let doc2 = svg_to_document(&svg);
        let children = doc2.layers[0].children().unwrap();
        let Element::Text(t) = &*children[0] else { panic!("expected Text"); };
        assert_eq!(t.tspans.len(), 3);
        assert_eq!(t.tspans[0].rotate, Some(45.0));
        assert_eq!(t.tspans[1].rotate, Some(90.0));
        assert_eq!(t.tspans[2].rotate, Some(0.0));
    }

    #[test]
    fn svg_phase8_justification_attrs_round_trip_through_document() {
        // Phase 1b2 / Phase 8: 11 Justification dialog attrs on a
        // paragraph wrapper round-trip through document SVG.
        use crate::geometry::tspan::Tspan;
        let mut doc = Document::default();
        let mut t = crate::tools::text_edit::empty_text_elem(0.0, 0.0, 0.0, 0.0);
        let mut wrapper = Tspan::default_tspan();
        wrapper.id = 0;
        wrapper.jas_role = Some("paragraph".into());
        wrapper.jas_word_spacing_min = Some(75.0);
        wrapper.jas_word_spacing_desired = Some(95.0);
        wrapper.jas_word_spacing_max = Some(150.0);
        wrapper.jas_letter_spacing_min = Some(-5.0);
        wrapper.jas_letter_spacing_desired = Some(0.0);
        wrapper.jas_letter_spacing_max = Some(10.0);
        wrapper.jas_glyph_scaling_min = Some(95.0);
        wrapper.jas_glyph_scaling_desired = Some(100.0);
        wrapper.jas_glyph_scaling_max = Some(105.0);
        wrapper.jas_auto_leading = Some(140.0);
        wrapper.jas_single_word_justify = Some("left".into());
        t.tspans = vec![
            wrapper,
            Tspan { id: 1, content: "x".into(), ..Tspan::default_tspan() },
        ];
        doc.layers[0].children_mut().unwrap()
            .push(std::rc::Rc::new(Element::Text(t)));
        let svg = document_to_svg(&doc);
        // Spot-check a few attributes appear with the urn:jas:1: prefix.
        assert!(svg.contains(r#"urn:jas:1:word-spacing-min="75""#));
        assert!(svg.contains(r#"urn:jas:1:letter-spacing-desired="0""#));
        assert!(svg.contains(r#"urn:jas:1:glyph-scaling-max="105""#));
        assert!(svg.contains(r#"urn:jas:1:auto-leading="140""#));
        assert!(svg.contains(r#"urn:jas:1:single-word-justify="left""#));
        let doc2 = svg_to_document(&svg);
        let children = doc2.layers[0].children().unwrap();
        let Element::Text(t) = &*children[0] else { panic!("expected Text"); };
        let w = &t.tspans[0];
        assert_eq!(w.jas_word_spacing_min, Some(75.0));
        assert_eq!(w.jas_word_spacing_desired, Some(95.0));
        assert_eq!(w.jas_word_spacing_max, Some(150.0));
        assert_eq!(w.jas_letter_spacing_min, Some(-5.0));
        assert_eq!(w.jas_letter_spacing_desired, Some(0.0));
        assert_eq!(w.jas_letter_spacing_max, Some(10.0));
        assert_eq!(w.jas_glyph_scaling_min, Some(95.0));
        assert_eq!(w.jas_glyph_scaling_desired, Some(100.0));
        assert_eq!(w.jas_glyph_scaling_max, Some(105.0));
        assert_eq!(w.jas_auto_leading, Some(140.0));
        assert_eq!(w.jas_single_word_justify.as_deref(), Some("left"));
    }

    #[test]
    fn svg_phase9_hyphenation_attrs_round_trip_through_document() {
        // Phase 1b3 / Phase 9: 7 Hyphenation dialog attrs on a
        // paragraph wrapper round-trip through document SVG.
        use crate::geometry::tspan::Tspan;
        let mut doc = Document::default();
        let mut t = crate::tools::text_edit::empty_text_elem(0.0, 0.0, 0.0, 0.0);
        let mut wrapper = Tspan::default_tspan();
        wrapper.id = 0;
        wrapper.jas_role = Some("paragraph".into());
        wrapper.jas_hyphenate_min_word = Some(6.0);
        wrapper.jas_hyphenate_min_before = Some(3.0);
        wrapper.jas_hyphenate_min_after = Some(2.0);
        wrapper.jas_hyphenate_limit = Some(2.0);
        wrapper.jas_hyphenate_zone = Some(36.0);
        wrapper.jas_hyphenate_bias = Some(0.5);
        wrapper.jas_hyphenate_capitalized = Some(true);
        t.tspans = vec![
            wrapper,
            Tspan { id: 1, content: "x".into(), ..Tspan::default_tspan() },
        ];
        doc.layers[0].children_mut().unwrap()
            .push(std::rc::Rc::new(Element::Text(t)));
        let svg = document_to_svg(&doc);
        assert!(svg.contains(r#"urn:jas:1:hyphenate-min-word="6""#));
        assert!(svg.contains(r#"urn:jas:1:hyphenate-min-before="3""#));
        assert!(svg.contains(r#"urn:jas:1:hyphenate-min-after="2""#));
        assert!(svg.contains(r#"urn:jas:1:hyphenate-limit="2""#));
        assert!(svg.contains(r#"urn:jas:1:hyphenate-zone="36""#));
        assert!(svg.contains(r#"urn:jas:1:hyphenate-bias="0.5""#));
        assert!(svg.contains(r#"urn:jas:1:hyphenate-capitalized="true""#));
        let doc2 = svg_to_document(&svg);
        let children = doc2.layers[0].children().unwrap();
        let Element::Text(t) = &*children[0] else { panic!("expected Text"); };
        let w = &t.tspans[0];
        assert_eq!(w.jas_hyphenate_min_word, Some(6.0));
        assert_eq!(w.jas_hyphenate_min_before, Some(3.0));
        assert_eq!(w.jas_hyphenate_min_after, Some(2.0));
        assert_eq!(w.jas_hyphenate_limit, Some(2.0));
        assert_eq!(w.jas_hyphenate_zone, Some(36.0));
        assert_eq!(w.jas_hyphenate_bias, Some(0.5));
        assert_eq!(w.jas_hyphenate_capitalized, Some(true));
    }
}
