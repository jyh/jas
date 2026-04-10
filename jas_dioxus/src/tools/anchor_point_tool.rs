//! Anchor Point (Convert Anchor Point) tool.
//!
//! Three interactions:
//! - Drag on a corner point: pull out symmetric control handles (→ smooth).
//! - Click on a smooth point: collapse handles to anchor (→ corner).
//! - Drag on a control handle: move that handle independently (→ cusp).

use web_sys::CanvasRenderingContext2d;

use crate::document::document::ElementSelection;
use crate::document::model::Model;
use crate::geometry::element::{
    control_points, convert_corner_to_smooth, convert_smooth_to_corner,
    is_smooth_point, move_path_handle_independent, path_handle_positions, Element, PathElem,
};

use super::tool::{CanvasTool, HIT_RADIUS};

#[derive(Debug, Clone)]
enum State {
    Idle,
    /// Dragging from a corner anchor to pull out handles.
    DraggingCorner {
        path: Vec<usize>,
        pe: PathElem,
        anchor_idx: usize,
        start_x: f64,
        start_y: f64,
    },
    /// Dragging a control handle independently (cusp).
    DraggingHandle {
        path: Vec<usize>,
        pe: PathElem,
        anchor_idx: usize,
        handle_type: String,
        start_hx: f64,
        start_hy: f64,
    },
    /// Pressed on a smooth point — will convert to corner on release if no drag.
    PressedSmooth {
        path: Vec<usize>,
        pe: PathElem,
        anchor_idx: usize,
        start_x: f64,
        start_y: f64,
    },
}

pub struct AnchorPointTool {
    state: State,
}

impl AnchorPointTool {
    pub fn new() -> Self {
        Self { state: State::Idle }
    }

    /// Hit-test bezier handles on all path elements (not just selected ones).
    fn hit_test_handle(
        model: &Model, x: f64, y: f64,
    ) -> Option<(Vec<usize>, PathElem, usize, String, f64, f64)> {
        let doc = model.document();
        for (li, layer) in doc.layers.iter().enumerate() {
            if let Some(children) = layer.children() {
                for (ci, child) in children.iter().enumerate() {
                    if let Element::Path(pe) = &**child
                        && let Some(result) = check_handles(pe, &[li, ci], x, y) {
                            return Some(result);
                        }
                    if let Element::Group(g) = &**child {
                        if child.common().locked { continue; }
                        for (gi, gc) in g.children.iter().enumerate() {
                            if let Element::Path(pe) = &**gc
                                && let Some(result) = check_handles(pe, &[li, ci, gi], x, y) {
                                    return Some(result);
                                }
                        }
                    }
                }
            }
        }
        None
    }

    /// Hit-test anchor points on all path elements.
    fn hit_test_anchor(
        model: &Model, x: f64, y: f64,
    ) -> Option<(Vec<usize>, PathElem, usize)> {
        let doc = model.document();
        for (li, layer) in doc.layers.iter().enumerate() {
            if let Some(children) = layer.children() {
                for (ci, child) in children.iter().enumerate() {
                    if let Element::Path(pe) = &**child
                        && let Some(idx) = find_anchor_at(pe, x, y) {
                            return Some((vec![li, ci], pe.clone(), idx));
                        }
                    if let Element::Group(g) = &**child {
                        if child.common().locked { continue; }
                        for (gi, gc) in g.children.iter().enumerate() {
                            if let Element::Path(pe) = &**gc
                                && let Some(idx) = find_anchor_at(pe, x, y) {
                                    return Some((vec![li, ci, gi], pe.clone(), idx));
                                }
                        }
                    }
                }
            }
        }
        None
    }

    fn select_all_cps(model: &mut Model, path: &[usize], _elem: &Element) {
        let mut doc = model.document().clone();
        doc.selection.retain(|es| es.path != path);
        doc.selection.push(ElementSelection::all(path.to_vec()));
        model.set_document(doc);
    }
}

fn check_handles(
    pe: &PathElem, path: &[usize], x: f64, y: f64,
) -> Option<(Vec<usize>, PathElem, usize, String, f64, f64)> {
    let anchors = control_points(&Element::Path(pe.clone()));
    for (ai, _) in anchors.iter().enumerate() {
        let (h_in, h_out) = path_handle_positions(&pe.d, ai);
        if let Some((hx, hy)) = h_in
            && ((x - hx).powi(2) + (y - hy).powi(2)).sqrt() < HIT_RADIUS {
                return Some((path.to_vec(), pe.clone(), ai, "in".to_string(), hx, hy));
            }
        if let Some((hx, hy)) = h_out
            && ((x - hx).powi(2) + (y - hy).powi(2)).sqrt() < HIT_RADIUS {
                return Some((path.to_vec(), pe.clone(), ai, "out".to_string(), hx, hy));
            }
    }
    None
}

fn find_anchor_at(pe: &PathElem, px: f64, py: f64) -> Option<usize> {
    let anchors = control_points(&Element::Path(pe.clone()));
    for (i, &(ax, ay)) in anchors.iter().enumerate() {
        if ((px - ax).powi(2) + (py - ay).powi(2)).sqrt() < HIT_RADIUS {
            return Some(i);
        }
    }
    None
}

impl CanvasTool for AnchorPointTool {
    fn on_press(&mut self, model: &mut Model, x: f64, y: f64, _shift: bool, _alt: bool) {
        // 1. Check handle hit first (for cusp behavior)
        if let Some((path, pe, anchor_idx, handle_type, hx, hy)) =
            Self::hit_test_handle(model, x, y)
        {
            self.state = State::DraggingHandle {
                path,
                pe,
                anchor_idx,
                handle_type,
                start_hx: hx,
                start_hy: hy,
            };
            return;
        }

        // 2. Check anchor point hit
        if let Some((path, pe, anchor_idx)) = Self::hit_test_anchor(model, x, y) {
            if is_smooth_point(&pe.d, anchor_idx) {
                // Smooth point — will convert to corner on click, or ignore drag
                self.state = State::PressedSmooth {
                    path,
                    pe,
                    anchor_idx,
                    start_x: x,
                    start_y: y,
                };
            } else {
                // Corner point — start dragging to pull out handles
                self.state = State::DraggingCorner {
                    path,
                    pe,
                    anchor_idx,
                    start_x: x,
                    start_y: y,
                };
            }
        }
    }

    fn on_move(&mut self, model: &mut Model, x: f64, y: f64, _shift: bool, _alt: bool, dragging: bool) {
        if !dragging {
            return;
        }

        match &self.state {
            State::DraggingCorner { path, pe, anchor_idx, .. } => {
                // Live preview: convert corner to smooth with handles at drag position
                let new_pe = convert_corner_to_smooth(pe, *anchor_idx, x, y);
                let new_elem = Element::Path(new_pe);
                let doc = model.document().replace_element(path, new_elem.clone());
                model.set_document(doc);
            }
            State::DraggingHandle { path, pe, anchor_idx, handle_type, start_hx, start_hy } => {
                // Move handle independently (cusp)
                let dx = x - start_hx;
                let dy = y - start_hy;
                let new_pe = move_path_handle_independent(pe, *anchor_idx, handle_type, dx, dy);
                let new_elem = Element::Path(new_pe);
                let doc = model.document().replace_element(path, new_elem.clone());
                model.set_document(doc);
            }
            State::PressedSmooth { start_x, start_y, path, pe, anchor_idx } => {
                // If dragged far enough from a smooth point, start pulling handles
                // (convert the interaction to a corner-drag)
                let dist = ((x - start_x).powi(2) + (y - start_y).powi(2)).sqrt();
                if dist > 3.0 {
                    // Convert to corner first, then start pulling new handles
                    let corner_pe = convert_smooth_to_corner(pe, *anchor_idx);
                    let new_pe = convert_corner_to_smooth(&corner_pe, *anchor_idx, x, y);
                    let new_elem = Element::Path(new_pe);
                    let doc = model.document().replace_element(path, new_elem.clone());
                    model.set_document(doc);

                    self.state = State::DraggingCorner {
                        path: path.clone(),
                        pe: corner_pe,
                        anchor_idx: *anchor_idx,
                        start_x: *start_x,
                        start_y: *start_y,
                    };
                }
            }
            State::Idle => {}
        }
    }

    fn on_release(&mut self, model: &mut Model, _x: f64, _y: f64, _shift: bool, _alt: bool) {
        let state = std::mem::replace(&mut self.state, State::Idle);
        match state {
            State::PressedSmooth { path, pe, anchor_idx, .. } => {
                // Click on smooth point → convert to corner
                model.snapshot();
                let new_pe = convert_smooth_to_corner(&pe, anchor_idx);
                let new_elem = Element::Path(new_pe.clone());
                let doc = model.document().replace_element(&path, new_elem.clone());
                model.set_document(doc);
                Self::select_all_cps(model, &path, &new_elem);
            }
            State::DraggingCorner { path, pe, anchor_idx, start_x, start_y, .. } => {
                let dist = ((_x - start_x).powi(2) + (_y - start_y).powi(2)).sqrt();
                if dist > 1.0 {
                    // Commit the corner→smooth conversion
                    model.snapshot();
                    let new_pe = convert_corner_to_smooth(&pe, anchor_idx, _x, _y);
                    let new_elem = Element::Path(new_pe);
                    let doc = model.document().replace_element(&path, new_elem.clone());
                    model.set_document(doc);
                    Self::select_all_cps(model, &path, &new_elem);
                }
            }
            State::DraggingHandle { path, pe, anchor_idx, handle_type, start_hx, start_hy } => {
                let dx = _x - start_hx;
                let dy = _y - start_hy;
                if dx.abs() > 0.5 || dy.abs() > 0.5 {
                    model.snapshot();
                    let new_pe = move_path_handle_independent(&pe, anchor_idx, &handle_type, dx, dy);
                    let new_elem = Element::Path(new_pe);
                    let doc = model.document().replace_element(&path, new_elem.clone());
                    model.set_document(doc);
                    Self::select_all_cps(model, &path, &new_elem);
                }
            }
            State::Idle => {}
        }
    }

    fn draw_overlay(&self, _model: &Model, _ctx: &CanvasRenderingContext2d) {
        // No overlay needed
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::geometry::element::PathCommand;

    fn make_line_path() -> PathElem {
        PathElem {
            d: vec![
                PathCommand::MoveTo { x: 0.0, y: 0.0 },
                PathCommand::LineTo { x: 50.0, y: 0.0 },
                PathCommand::LineTo { x: 100.0, y: 0.0 },
            ],
            fill: None,
            stroke: None,
            common: Default::default(),
        }
    }

    fn make_smooth_path() -> PathElem {
        PathElem {
            d: vec![
                PathCommand::MoveTo { x: 0.0, y: 0.0 },
                PathCommand::CurveTo { x1: 10.0, y1: 20.0, x2: 40.0, y2: 20.0, x: 50.0, y: 0.0 },
                PathCommand::CurveTo { x1: 60.0, y1: -20.0, x2: 90.0, y2: -20.0, x: 100.0, y: 0.0 },
            ],
            fill: None,
            stroke: None,
            common: Default::default(),
        }
    }

    #[test]
    fn corner_point_is_not_smooth() {
        let pe = make_line_path();
        assert!(!is_smooth_point(&pe.d, 0)); // MoveTo
        assert!(!is_smooth_point(&pe.d, 1)); // LineTo - no handles
        assert!(!is_smooth_point(&pe.d, 2)); // LineTo - no handles
    }

    #[test]
    fn smooth_point_is_smooth() {
        let pe = make_smooth_path();
        // Anchor at index 1 (50,0) has incoming handle (40,20) and outgoing (60,-20)
        assert!(is_smooth_point(&pe.d, 1));
    }

    #[test]
    fn convert_corner_to_smooth_creates_handles() {
        let pe = make_line_path();
        // Convert anchor 1 (at 50,0) to smooth by dragging to (50, 30)
        let result = convert_corner_to_smooth(&pe, 1, 50.0, 30.0);
        // Should have CurveTo commands now
        assert!(matches!(result.d[1], PathCommand::CurveTo { .. }));
        // Outgoing handle on next segment should be at (50,30)
        if let PathCommand::CurveTo { x1, y1, .. } = result.d[2] {
            assert!((x1 - 50.0).abs() < 0.01);
            assert!((y1 - 30.0).abs() < 0.01);
        } else {
            panic!("expected CurveTo for segment after converted point");
        }
        // Incoming handle should be reflected: (50, -30)
        if let PathCommand::CurveTo { x2, y2, .. } = result.d[1] {
            assert!((x2 - 50.0).abs() < 0.01);
            assert!((y2 - (-30.0)).abs() < 0.01);
        } else {
            panic!("expected CurveTo");
        }
    }

    #[test]
    fn convert_smooth_to_corner_collapses_handles() {
        let pe = make_smooth_path();
        let result = convert_smooth_to_corner(&pe, 1);
        // After conversion, anchor 1 should have no visible handles
        assert!(!is_smooth_point(&result.d, 1));
        // The x2,y2 of cmd[1] should equal the anchor (50,0)
        if let PathCommand::CurveTo { x2, y2, x, y, .. } = result.d[1] {
            assert!((x2 - x).abs() < 0.01);
            assert!((y2 - y).abs() < 0.01);
        }
        // The x1,y1 of cmd[2] should equal the anchor (50,0)
        if let PathCommand::CurveTo { x1, y1, .. } = result.d[2] {
            assert!((x1 - 50.0).abs() < 0.01);
            assert!((y1 - 0.0).abs() < 0.01);
        }
    }

    #[test]
    fn independent_handle_move_does_not_reflect() {
        let pe = make_smooth_path();
        // Move the outgoing handle of anchor 1 by (10, 5)
        let result = move_path_handle_independent(&pe, 1, "out", 10.0, 5.0);
        // Outgoing handle (x1 of cmd[2]) should be moved
        if let PathCommand::CurveTo { x1, y1, .. } = result.d[2] {
            assert!((x1 - 70.0).abs() < 0.01); // 60 + 10
            assert!((y1 - (-15.0)).abs() < 0.01); // -20 + 5
        }
        // Incoming handle (x2 of cmd[1]) should NOT be changed
        if let PathCommand::CurveTo { x2, y2, .. } = result.d[1] {
            assert!((x2 - 40.0).abs() < 0.01); // unchanged
            assert!((y2 - 20.0).abs() < 0.01); // unchanged
        }
    }

    #[test]
    fn find_anchor_at_hits_near_point() {
        let pe = make_line_path();
        // Point near anchor 1 (50, 0)
        assert_eq!(find_anchor_at(&pe, 51.0, 1.0), Some(1));
        // Point far from any anchor
        assert_eq!(find_anchor_at(&pe, 200.0, 200.0), None);
    }

    #[test]
    fn convert_first_anchor_corner_to_smooth() {
        let pe = make_line_path();
        // Convert anchor 0 (MoveTo at 0,0) — only outgoing handle
        let result = convert_corner_to_smooth(&pe, 0, 10.0, 20.0);
        // The next command should get the outgoing handle
        if let PathCommand::CurveTo { x1, y1, .. } = result.d[1] {
            assert!((x1 - 10.0).abs() < 0.01);
            assert!((y1 - 20.0).abs() < 0.01);
        } else {
            panic!("expected CurveTo after converting first anchor");
        }
    }

    #[test]
    fn convert_last_anchor_corner_to_smooth() {
        let pe = make_line_path();
        // Convert anchor 2 (last, LineTo at 100,0) — only incoming handle
        let result = convert_corner_to_smooth(&pe, 2, 100.0, 30.0);
        // The incoming handle (x2,y2 on this cmd) should be the reflected position
        if let PathCommand::CurveTo { x2, y2, x, y, .. } = result.d[2] {
            // Reflected of (100,30) through (100,0) = (100,-30)
            assert!((x2 - 100.0).abs() < 0.01);
            assert!((y2 - (-30.0)).abs() < 0.01);
            assert!((x - 100.0).abs() < 0.01);
            assert!((y - 0.0).abs() < 0.01);
        } else {
            panic!("expected CurveTo");
        }
    }
}
