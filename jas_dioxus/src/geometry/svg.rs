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

fn element_svg(elem: &Element, indent: &str) -> String {
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
            let td_attr = if e.text_decoration != "none" {
                format!(" text-decoration=\"{}\"", e.text_decoration)
            } else { String::new() };
            // SVG `y` is the baseline of the first line; internally
            // `e.y` is the *top* of the layout box, so add the ascent
            // (0.8 * font_size, the same value `text_layout` uses).
            let svg_y = e.y + e.font_size * 0.8;
            format!(
                "{}<text x=\"{}\" y=\"{}\" font-family=\"{}\" font-size=\"{}\"{}{}{}{}{}{}{}>{}</text>\n",
                indent,
                fmt(px(e.x)), fmt(px(svg_y)),
                escape_xml(&e.font_family), fmt(px(e.font_size)),
                fw_attr, fst_attr, td_attr,
                area_attrs,
                fill_attrs(&e.fill), stroke_attrs(&e.stroke),
                opacity_attr(e.common.opacity),
                escape_xml(&e.content),
            )
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
            let td_attr = if e.text_decoration != "none" {
                format!(" text-decoration=\"{}\"", e.text_decoration)
            } else { String::new() };
            format!(
                "{}<text{}{} font-family=\"{}\" font-size=\"{}\"{}{}{}{}{}><textPath path=\"{}\"{}>{}</textPath></text>\n",
                indent,
                fill_attrs(&e.fill), stroke_attrs(&e.stroke),
                escape_xml(&e.font_family), fmt(px(e.font_size)),
                fw_attr, fst_attr, td_attr,
                opacity_attr(e.common.opacity), transform_attr(&e.common.transform),
                path_data(&e.d), offset_attr,
                escape_xml(&e.content),
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
    Some(Stroke { color, width, linecap: lc, linejoin: lj, miter_limit: 10.0, align: StrokeAlign::Center, dash_pattern: [0.0; 6], dash_len: 0, opacity })
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
                common,
            }))
        }
        "text" => {
            let ff = get_s(node, "font-family", "sans-serif").to_string();
            let fs = pt(get_f(node, "font-size", 16.0));
            let fw = get_s(node, "font-weight", "normal").to_string();
            let fst = get_s(node, "font-style", "normal").to_string();
            let td = get_s(node, "text-decoration", "none").to_string();

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
                    return Some(Element::TextPath(TextPathElem {
                        d, content: child.text.clone(), start_offset,
                        font_family: ff, font_size: fs,
                        font_weight: fw, font_style: fst, text_decoration: td,
                        fill: parse_fill(node), stroke: parse_stroke(node),
                        common,
                    }));
                }
            }

            let content = node.text.clone();
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
                content, font_family: ff, font_size: fs,
                font_weight: fw, font_style: fst, text_decoration: td,
                width: tw, height: th,
                fill: parse_fill(node), stroke: parse_stroke(node),
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
                Some(Element::Layer(LayerElem { children, name, common }))
            } else {
                Some(Element::Group(GroupElem { children, common }))
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
                    }));
                } else if let Some(Element::Layer(le)) = layers.last_mut() {
                    le.children.push(Rc::new(elem));
                }
            }
        }
    }
    if layers.is_empty() {
        return Document::default();
    }
    let doc = Document {
        layers,
        selected_layer: 0,
        selection: Vec::new(),
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
                common: CommonProps::default(),
            })],
            selected_layer: 0,
            selection: vec![],
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
        let t = TextElem {
            x: 10.0, y: 20.0, content: "Hi".into(),
            font_family: "sans-serif".into(), font_size: 16.0,
            font_weight: "normal".into(), font_style: "normal".into(),
            text_decoration: "none".into(),
            width: 0.0, height: 0.0,
            fill: Some(Fill::new(Color::BLACK)), stroke: None,
            common: CommonProps::default(),
        };
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
            stroke: Some(Stroke { color: Color::BLACK, width: 1.0, linecap: LineCap::Butt, linejoin: LineJoin::Miter, opacity: 0.4 }),
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
            stroke: Some(Stroke { color: Color::new(0.0, 0.0, 0.0, 0.25), width: 1.0, linecap: LineCap::Butt, linejoin: LineJoin::Miter, opacity: 1.0 }),
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
}
