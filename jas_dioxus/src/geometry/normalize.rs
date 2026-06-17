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
        // Masters get the same opacity normalization as layer content.
        symbols: doc.symbols.iter().map(|m| normalize_element(m)).collect(),
        selected_layer: doc.selected_layer,
        selection: doc.selection.clone(),
        artboards: doc.artboards.clone(),
        artboard_options: doc.artboard_options.clone(),
        document_setup: doc.document_setup.clone(),
        print_preferences: doc.print_preferences.clone(),
    }
}

/// Enforce the unique-id invariant after import (REFERENCE_GRAPH.md §2.5):
/// walk the document in canonical pre-order; the FIRST element to use a given
/// id keeps it, and every later element carrying the same id has its id
/// cleared to None (first-pre-order-wins). Element ids are then unique within
/// the document, so the live-reference index never collides. A no-op on a
/// document whose ids are already unique (the normal case) — well-formed
/// documents round-trip unchanged; only ill-formed (e.g. foreign-SVG)
/// duplicates are normalized. Called by every document reader.
pub fn dedupe_element_ids(doc: &Document) -> Document {
    let mut seen: std::collections::HashSet<String> = std::collections::HashSet::new();
    let mut layers: Vec<Element> = doc.layers.clone();
    for l in layers.iter_mut() {
        dedupe_ids_walk(l, &mut seen);
    }
    // The id space spans layers + symbols (SYMBOLS.md §6): the master store is
    // part of the same pre-order walk so a master id can never collide with a
    // layer-element id. Layers walk first (first-pre-order-wins), then symbols.
    let mut symbols: Vec<Element> = doc.symbols.clone();
    for m in symbols.iter_mut() {
        dedupe_ids_walk(m, &mut seen);
    }
    Document {
        layers,
        symbols,
        selected_layer: doc.selected_layer,
        selection: doc.selection.clone(),
        artboards: doc.artboards.clone(),
        artboard_options: doc.artboard_options.clone(),
        document_setup: doc.document_setup.clone(),
        print_preferences: doc.print_preferences.clone(),
    }
}

fn dedupe_ids_walk(elem: &mut Element, seen: &mut std::collections::HashSet<String>) {
    if let Some(id) = elem.common().id.clone() {
        // `insert` returns false when the id was already present — that
        // marks this as a later duplicate, so clear it.
        if !seen.insert(id) {
            elem.common_mut().id = None;
        }
    }
    if let Some(children) = elem.children_mut() {
        for child in children.iter_mut() {
            dedupe_ids_walk(Rc::make_mut(child), seen);
        }
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
            crate::geometry::live::LiveVariant::Reference(r) => Element::Live(
                crate::geometry::live::LiveVariant::Reference(crate::geometry::live::ReferenceElem {
                    fill: r.fill.as_ref().map(normalize_fill),
                    stroke: r.stroke.as_ref().map(normalize_stroke),
                    ..r.clone()
                }),
            ),
        },
    }
}
