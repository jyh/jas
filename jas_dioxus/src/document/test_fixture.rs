//! Document fixtures shared by test arms across modules: a black rect and a
//! one-layer model with chosen children selected.

use crate::document::document::{Document, ElementSelection};
use crate::document::model::Model;
use crate::geometry::element::{Color, CommonProps, Element, Fill, LayerElem, RectElem};

pub(crate) fn rect(x: f64, y: f64, w: f64, h: f64) -> Element {
    Element::Rect(RectElem {
        x, y, width: w, height: h, rx: 0.0, ry: 0.0,
        fill: Some(Fill::new(Color::BLACK)), stroke: None,
        common: CommonProps::default(),
        fill_gradient: None,
        stroke_gradient: None,
    })
}

/// A stroked two-point path carrying `brush` as its `stroke_brush` (W2b-18's
/// brushed stroke when the id is non-empty).
pub(crate) fn brushed_path(x: f64, brush: Option<&str>) -> Element {
    use crate::geometry::element::{FillRule, PathCommand, PathElem, Stroke};
    Element::Path(PathElem {
        d: vec![PathCommand::MoveTo { x, y: 0.0 }, PathCommand::LineTo { x: x + 50.0, y: 40.0 }],
        fill: None,
        stroke: Some(Stroke::new(Color::BLACK, 2.0)),
        width_points: vec![],
        common: CommonProps::default(),
        fill_gradient: None,
        stroke_gradient: None,
        stroke_brush: brush.map(String::from),
        stroke_brush_overrides: None,
        fill_rule: FillRule::NonZero,
    })
}

/// One layer holding `rects`, with `selected` (child indices) selected.
/// Seeded unbracketed, so the model starts with nothing to undo.
pub(crate) fn model_with(rects: Vec<Element>, selected: &[usize]) -> Model {
    let layer = Element::Layer(LayerElem {
        children: rects.into_iter().map(std::rc::Rc::new).collect(),
        isolated_blending: false,
        knockout_group: false,
        common: CommonProps { name: Some("L".into()), ..Default::default() },
    });
    let selection = selected.iter().map(|&i| ElementSelection::all(vec![0, i])).collect();
    let doc = Document { layers: vec![layer], selected_layer: 0, selection,
                         ..Document::default() };
    let mut model = Model::default();
    model.set_document_for_test(doc);
    model
}

/// Two rects at different x and y, both selected unless told otherwise.
pub(crate) fn misaligned(selected: &[usize]) -> Model {
    model_with(vec![rect(10.0, 0.0, 5.0, 5.0), rect(40.0, 20.0, 5.0, 5.0)], selected)
}

/// A group holding `children` (the Brushes menu's Select All Unused walks
/// into groups).
pub(crate) fn group(children: Vec<Element>) -> Element {
    use crate::geometry::element::GroupElem;
    Element::Group(GroupElem {
        children: children.into_iter().map(std::rc::Rc::new).collect(),
        common: CommonProps::default(),
        isolated_blending: false,
        knockout_group: false,
    })
}
