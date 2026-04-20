//! SVG opacity normalizer.
//!
//! Extracts color alpha into fill/stroke opacity (multiplicative),
//! then sets color alpha to 1.0.  This ensures that element
//! transparency is expressed through opacity attributes rather than
//! color alpha channels.

use std::rc::Rc;

use crate::document::document::Document;
use crate::geometry::element::*;

/// Normalize all elements in a document: extract color alpha into
/// fill/stroke opacity and set color alpha to 1.0.
pub fn normalize_document(doc: &Document) -> Document {
    Document {
        layers: doc.layers.iter().map(|l| normalize_element(l)).collect(),
        selected_layer: doc.selected_layer,
        selection: doc.selection.clone(),
    }
}

fn normalize_fill(fill: &Fill) -> Fill {
    let alpha = fill.color.alpha();
    Fill {
        color: fill.color.with_alpha(1.0),
        opacity: fill.opacity * alpha,
    }
}

fn normalize_stroke(stroke: &Stroke) -> Stroke {
    let alpha = stroke.color.alpha();
    Stroke {
        color: stroke.color.with_alpha(1.0),
        opacity: stroke.opacity * alpha,
        ..*stroke
    }
}

fn normalize_element(elem: &Element) -> Element {
    match elem {
        Element::Line(e) => Element::Line(LineElem {
            stroke: e.stroke.as_ref().map(normalize_stroke),
            ..e.clone()
        }),
        Element::Rect(e) => Element::Rect(RectElem {
            fill: e.fill.as_ref().map(normalize_fill),
            stroke: e.stroke.as_ref().map(normalize_stroke),
            ..e.clone()
        }),
        Element::Circle(e) => Element::Circle(CircleElem {
            fill: e.fill.as_ref().map(normalize_fill),
            stroke: e.stroke.as_ref().map(normalize_stroke),
            ..e.clone()
        }),
        Element::Ellipse(e) => Element::Ellipse(EllipseElem {
            fill: e.fill.as_ref().map(normalize_fill),
            stroke: e.stroke.as_ref().map(normalize_stroke),
            ..e.clone()
        }),
        Element::Polyline(e) => Element::Polyline(PolylineElem {
            fill: e.fill.as_ref().map(normalize_fill),
            stroke: e.stroke.as_ref().map(normalize_stroke),
            ..e.clone()
        }),
        Element::Polygon(e) => Element::Polygon(PolygonElem {
            fill: e.fill.as_ref().map(normalize_fill),
            stroke: e.stroke.as_ref().map(normalize_stroke),
            ..e.clone()
        }),
        Element::Path(e) => Element::Path(PathElem {
            fill: e.fill.as_ref().map(normalize_fill),
            stroke: e.stroke.as_ref().map(normalize_stroke),
            ..e.clone()
        }),
        Element::Text(e) => Element::Text(TextElem {
            fill: e.fill.as_ref().map(normalize_fill),
            stroke: e.stroke.as_ref().map(normalize_stroke),
            ..e.clone()
        }),
        Element::TextPath(e) => Element::TextPath(TextPathElem {
            fill: e.fill.as_ref().map(normalize_fill),
            stroke: e.stroke.as_ref().map(normalize_stroke),
            ..e.clone()
        }),
        Element::Group(g) => Element::Group(GroupElem {
            children: g.children.iter().map(|c| Rc::new(normalize_element(c))).collect(),
            ..g.clone()
        }),
        Element::Layer(l) => Element::Layer(LayerElem {
            children: l.children.iter().map(|c| Rc::new(normalize_element(c))).collect(),
            ..l.clone()
        }),
        Element::Live(v) => match v {
            crate::geometry::live::LiveVariant::CompoundShape(cs) => Element::Live(
                crate::geometry::live::LiveVariant::CompoundShape(crate::geometry::live::CompoundShape {
                    operands: cs.operands.iter()
                        .map(|c| Rc::new(normalize_element(c)))
                        .collect(),
                    fill: cs.fill.as_ref().map(normalize_fill),
                    stroke: cs.stroke.as_ref().map(normalize_stroke),
                    ..cs.clone()
                }),
            ),
        },
    }
}
