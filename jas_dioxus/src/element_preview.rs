//! The Layers row's `element_preview` thumbnail (SCHEMA.md `element_preview`,
//! STATUS-jas row 52), as a complete, self-declaring SVG document.
//!
//! One copy, three readers: the web's Layers tree (`renderer::tree_preview_svg`),
//! the panel plan a native shell draws ([`attach_to_plan`], called by
//! `ffi::jas_panel_plan`), and, by the same rule, the Mac's `buildPreviewSvg`
//! (`LayersThumbnailBoxTests` is its twin). This module is NOT gated, because
//! `interpreter::renderer` is web-only and the FFI build could not reach a
//! thumbnail living there.

use crate::document::document::Document;
use crate::geometry::element::Element;
use serde_json::Value;

/// Build a fitted-viewBox SVG thumbnail for a single element.
/// Returns an empty string for zero-extent or degenerate bounds.
pub fn preview_svg(elem: &Element) -> String {
    let (x, y, w, h) = elem.bounds();
    if !(w.is_finite() && h.is_finite()) || w <= 0.0 || h <= 0.0 {
        return String::new();
    }
    // element_svg() applies a pt → px scale (96/72 ≈ 1.333) to every
    // coordinate, since its primary callers export to standard SVG
    // files. The viewBox needs the same scale so the inner geometry
    // sits inside the declared box — otherwise content extends 1.333×
    // past the right/bottom and the SVG viewport clips it to the
    // upper-left of the thumbnail container.
    const PT_TO_PX: f64 = 96.0 / 72.0;
    let (x, y, w, h) = (x * PT_TO_PX, y * PT_TO_PX, w * PT_TO_PX, h * PT_TO_PX);
    let pad = (w.max(h) * 0.02).max(0.5);
    let vb = format!("{} {} {} {}", x - pad, y - pad, w + 2.0 * pad, h + 2.0 * pad);
    let inner = crate::geometry::svg::element_svg(elem, "");
    format!(
        // DECLARES xmlns:inkscape, because `element_svg` emits
        // `inkscape:label` for any element that HAS a name. Without it every
        // named element's row thumbnail is XML with an undeclared namespace
        // prefix -- which a strict parser rejects outright, and which this
        // codebase already learned once for the `jas:` prefix (see the
        // xmlns:jas assertion in CrossLanguageTests). It surfaced the day
        // renaming became easy in both ports: the thumbnails only carry a
        // label once elements have names.
        r#"<svg xmlns="http://www.w3.org/2000/svg" xmlns:inkscape="http://www.inkscape.org/namespaces/inkscape" xmlns:jas="urn:jas:1" viewBox="{vb}" preserveAspectRatio="xMidYMid meet" style="display:block;width:100%;height:100%;">{inner}</svg>"#
    )
}


/// The element path a plan leaf's `bind.element_path` names. A bind value
/// reaches the plan as a canonical STRING (`bind_values`: a list is `[0,1]`),
/// so the path is read back from its digit runs; `None` for an empty or
/// unreadable path.
#[allow(dead_code)] // Read only by attach_to_plan (below).
fn path_of(v: &Value) -> Option<Vec<usize>> {
    let s = v.as_str()?;
    let mut out = Vec::new();
    let mut cur: Option<usize> = None;
    for c in s.chars() {
        if let Some(d) = c.to_digit(10) {
            cur = Some(cur.unwrap_or(0) * 10 + d as usize);
        } else if let Some(n) = cur.take() {
            out.push(n);
        }
    }
    if let Some(n) = cur {
        out.push(n);
    }
    (!out.is_empty()).then_some(out)
}

/// Put each `element_preview` leaf's thumbnail into its `display` map as
/// `thumbnail.svg` (a complete SVG document, namespaces declared), for every
/// leaf whose `bind.element_path` names an element of `doc`. A leaf whose path
/// names nothing, or whose element has no extent, gets no key and draws its
/// blank square, as the spec says an empty container does. Every other leaf is
/// left untouched.
#[allow(dead_code)] // Called by ffi::jas_panel_plan; the web-only and bin builds do not compile ffi.
pub fn attach_to_plan(plan: &mut Value, doc: &Document) {
    let Some(leaves) = plan.get_mut("leaves").and_then(Value::as_array_mut) else { return };
    for leaf in leaves {
        if leaf.get("type").and_then(Value::as_str) != Some("element_preview") {
            continue;
        }
        let Some(path) = leaf.get("values").and_then(|v| v.get("bind.element_path")).and_then(path_of) else {
            continue;
        };
        let Some(elem) = doc.get_element(&path) else { continue };
        let svg = preview_svg(elem);
        if svg.is_empty() {
            continue;
        }
        if !leaf.get("display").is_some_and(Value::is_object) {
            leaf["display"] = Value::Object(serde_json::Map::new());
        }
        leaf["display"]["thumbnail.svg"] = Value::String(svg);
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn path_of_reads_the_canonical_list_string() {
        assert_eq!(path_of(&Value::String("[0,1]".into())), Some(vec![0, 1]));
        assert_eq!(path_of(&Value::String("[12, 3]".into())), Some(vec![12, 3]));
        assert_eq!(path_of(&Value::String("[]".into())), None);
        assert_eq!(path_of(&Value::Null), None);
    }

    /// This module's own lane-independent arm (the renderer's thumbnail arms
    /// run only in web builds): the document declares both prefixes and fits
    /// a px-scaled box.
    #[test]
    fn preview_svg_is_a_self_declaring_document() {
        use crate::geometry::element::{CommonProps, RectElem};
        let rect = Element::Rect(RectElem {
            x: 10.0, y: 10.0, width: 30.0, height: 30.0, rx: 0.0, ry: 0.0,
            fill: None, stroke: None, common: CommonProps::default(),
            fill_gradient: None, stroke_gradient: None,
        });
        let svg = preview_svg(&rect);
        assert!(svg.starts_with("<svg xmlns=\"http://www.w3.org/2000/svg\""), "{svg}");
        assert!(svg.contains("xmlns:inkscape=") && svg.contains("xmlns:jas="), "{svg}");
        assert!(svg.contains("<rect"), "{svg}");
    }
}
