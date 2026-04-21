//! Partial Selection tool — select individual control points and drag Bezier handles.
//!
//! State machine:
//!   IDLE     — waiting for input
//!   MARQUEE  — rubber-band selection rectangle
//!   MOVING   — dragging selected control points
//!   HANDLE   — dragging a Bezier handle

use web_sys::CanvasRenderingContext2d;

use crate::document::controller::Controller;
use crate::document::document::{ElementPath, ElementSelection};
use crate::document::model::Model;
use crate::geometry::element::{
    control_point_count, control_points, path_handle_positions, Element,
};

use super::tool::{CanvasTool, DRAG_THRESHOLD, HIT_RADIUS};

/// Look up the number of control points of the element at `path`.
/// Returns 0 if the path doesn't resolve.
fn elem_cp_count(model: &Model, path: &[usize]) -> usize {
    model.document().get_element(&path.to_vec())
        .map(control_point_count)
        .unwrap_or(0)
}

#[derive(Debug, Clone, PartialEq)]
enum State {
    Idle,
    Marquee {
        start_x: f64,
        start_y: f64,
        cur_x: f64,
        cur_y: f64,
    },
    /// Moving control points. The press starts here in `pending`
    /// state; the first `on_move` past `DRAG_THRESHOLD` snapshots the
    /// document and mutates it live on every subsequent move (matching
    /// the Selection tool — no dashed ghost). `last_x/last_y` are the
    /// previous mouse position so each move applies a per-tick delta.
    Moving {
        start_x: f64,
        start_y: f64,
        last_x: f64,
        last_y: f64,
        snapshotted: bool,
        copied: bool,
    },
    /// Dragging a Bezier handle. Same live-edit pattern as `Moving`.
    Handle {
        start_x: f64,
        start_y: f64,
        last_x: f64,
        last_y: f64,
        snapshotted: bool,
        path: ElementPath,
        anchor_idx: usize,
        handle_type: String, // "in" or "out"
    },
}

pub struct PartialSelectionTool {
    state: State,
}

impl PartialSelectionTool {
    pub fn new() -> Self {
        Self { state: State::Idle }
    }

    /// Hit-test Bezier handles on selected path elements.
    /// Returns (path, anchor_idx, "in"/"out") if a handle is hit.
    fn hit_test_handle(
        model: &Model,
        x: f64,
        y: f64,
    ) -> Option<(ElementPath, usize, String)> {
        let doc = model.document();
        for es in &doc.selection {
            if let Some(Element::Path(pe)) = doc.get_element(&es.path) {
                let anchors = control_points(&Element::Path(pe.clone()));
                for (ai, _) in anchors.iter().enumerate() {
                    let (h_in, h_out) = path_handle_positions(&pe.d, ai);
                    if let Some((hx, hy)) = h_in
                        && ((x - hx).powi(2) + (y - hy).powi(2)).sqrt() < HIT_RADIUS {
                            return Some((es.path.clone(), ai, "in".to_string()));
                        }
                    if let Some((hx, hy)) = h_out
                        && ((x - hx).powi(2) + (y - hy).powi(2)).sqrt() < HIT_RADIUS {
                            return Some((es.path.clone(), ai, "out".to_string()));
                        }
                }
            }
        }
        None
    }

    /// Hit-test individual control points on all elements.
    /// Returns (path, cp_index) if hit.
    fn hit_test_control_point(model: &Model, x: f64, y: f64) -> Option<(ElementPath, usize)> {
        use crate::geometry::element::Visibility;
        let doc = model.document();
        for (li, layer) in doc.layers.iter().enumerate() {
            let layer_vis = layer.visibility();
            if layer_vis == Visibility::Invisible {
                continue;
            }
            if let Some(children) = layer.children() {
                for (ci, child) in children.iter().enumerate().rev() {
                    if child.locked() {
                        continue;
                    }
                    let child_vis = std::cmp::min(layer_vis, child.visibility());
                    if child_vis == Visibility::Invisible {
                        continue;
                    }
                    let path = vec![li, ci];
                    // Check inside groups too
                    if let Some(result) = hit_test_cp_recursive(child, &path, child_vis, x, y) {
                        return Some(result);
                    }
                }
            }
        }
        None
    }

}

fn hit_test_cp_recursive(
    elem: &Element,
    path: &ElementPath,
    ancestor_vis: crate::geometry::element::Visibility,
    x: f64,
    y: f64,
) -> Option<(ElementPath, usize)> {
    use crate::geometry::element::Visibility;
    let effective = std::cmp::min(ancestor_vis, elem.visibility());
    if effective == Visibility::Invisible {
        return None;
    }
    if elem.is_group_or_layer() {
        if let Some(children) = elem.children() {
            for (i, child) in children.iter().enumerate().rev() {
                if child.locked() {
                    continue;
                }
                let mut child_path = path.clone();
                child_path.push(i);
                if let Some(result) = hit_test_cp_recursive(child, &child_path, effective, x, y) {
                    return Some(result);
                }
            }
        }
        return None;
    }
    let cps = control_points(elem);
    for (i, &(px, py)) in cps.iter().enumerate() {
        if ((x - px).powi(2) + (y - py).powi(2)).sqrt() < HIT_RADIUS {
            return Some((path.clone(), i));
        }
    }
    None
}

impl CanvasTool for PartialSelectionTool {
    fn on_press(&mut self, model: &mut Model, x: f64, y: f64, shift: bool, _alt: bool) {
        // 1. Check handle hit first
        if let Some((path, anchor_idx, handle_type)) = Self::hit_test_handle(model, x, y) {
            self.state = State::Handle {
                start_x: x,
                start_y: y,
                last_x: x,
                last_y: y,
                snapshotted: false,
                path,
                anchor_idx,
                handle_type,
            };
            return;
        }

        // 2. Check if clicking on any element's control point. The
        // Partial Selection tool treats a CP hit as "directly on a
        // selectable object"; everything else (empty space, element
        // body/fill without a CP hit) starts a new marquee.
        if let Some((path, cp_idx)) = Self::hit_test_control_point(model, x, y) {
            let already_selected = model.document().selection.iter()
                .any(|es| es.path == path && es.kind.contains(cp_idx));
            if !already_selected || shift {
                model.snapshot();
                if shift {
                    // Toggle this CP in selection. The XOR is computed via
                    // the per-CP `Vec<usize>` form so it works whether the
                    // existing entry is `All` or `Partial`.
                    use crate::document::document::{SelectionKind, SortedCps};
                    let doc = model.document();
                    let mut sel = doc.selection.clone();
                    if let Some(pos) = sel.iter().position(|es| es.path == path) {
                        let es = &sel[pos];
                        let total = elem_cp_count(model, &path);
                        let mut cps: Vec<usize> = es.kind.to_sorted(total).iter().collect();
                        if let Some(p) = cps.iter().position(|&i| i == cp_idx) {
                            cps.remove(p);
                        } else {
                            cps.push(cp_idx);
                        }
                        // Empty CP set is a legal state: "element
                        // selected, no CPs highlighted". Keep the
                        // entry rather than removing it.
                        sel[pos] = ElementSelection {
                            path: path.clone(),
                            kind: SelectionKind::Partial(SortedCps::from_iter(cps)),
                        };
                    } else {
                        sel.push(ElementSelection::partial(path.clone(), [cp_idx]));
                    }
                    Controller::set_selection(model, sel);
                } else {
                    // Replace the selection with just this CP.
                    Controller::select_control_point(model, &path, cp_idx);
                }
            }
            // Whether the CP was already selected or we just selected
            // it, the press starts a drag of the (current) selection.
            self.state = State::Moving {
                start_x: x,
                start_y: y,
                last_x: x,
                last_y: y,
                snapshotted: false,
                copied: false,
            };
            return;
        }

        // 3. No CP hit — start a new marquee. We deliberately do NOT
        // fall back to a "hit inside the bbox of a selected element"
        // check: with the Partial Selection tool, a drag that begins on
        // empty space or on a body/fill without a CP hit must marquee,
        // never move the existing selection.
        self.state = State::Marquee {
            start_x: x,
            start_y: y,
            cur_x: x,
            cur_y: y,
        };
    }

    fn on_move(&mut self, model: &mut Model, x: f64, y: f64, _shift: bool, alt: bool, _dragging: bool) {
        match &mut self.state {
            State::Marquee { cur_x, cur_y, .. } => {
                *cur_x = x;
                *cur_y = y;
            }
            State::Moving {
                start_x,
                start_y,
                last_x,
                last_y,
                snapshotted,
                copied,
            } => {
                let dist = ((x - *start_x).powi(2) + (y - *start_y).powi(2)).sqrt();
                if !*snapshotted {
                    if dist <= DRAG_THRESHOLD {
                        return;
                    }
                    model.snapshot();
                    *snapshotted = true;
                }
                let dx = x - *last_x;
                let dy = y - *last_y;
                if alt && !*copied {
                    Controller::copy_selection(model, dx, dy);
                    *copied = true;
                } else {
                    Controller::move_selection(model, dx, dy);
                }
                *last_x = x;
                *last_y = y;
            }
            State::Handle {
                start_x,
                start_y,
                last_x,
                last_y,
                snapshotted,
                path,
                anchor_idx,
                handle_type,
            } => {
                let dist = ((x - *start_x).powi(2) + (y - *start_y).powi(2)).sqrt();
                if !*snapshotted {
                    if dist <= 0.5 {
                        return;
                    }
                    model.snapshot();
                    *snapshotted = true;
                }
                let dx = x - *last_x;
                let dy = y - *last_y;
                Controller::move_path_handle(model, path, *anchor_idx, handle_type, dx, dy);
                *last_x = x;
                *last_y = y;
            }
            State::Idle => {}
        }
    }

    fn on_release(&mut self, model: &mut Model, x: f64, y: f64, shift: bool, _alt: bool) {
        let state = std::mem::replace(&mut self.state, State::Idle);
        match state {
            State::Marquee {
                start_x, start_y, ..
            } => {
                let rx = start_x.min(x);
                let ry = start_y.min(y);
                let rw = (x - start_x).abs();
                let rh = (y - start_y).abs();
                if rw > 1.0 || rh > 1.0 {
                    model.snapshot();
                    Controller::partial_select_rect(model, rx, ry, rw, rh, shift);
                } else if !shift {
                    Controller::set_selection(model, Vec::new());
                }
            }
            // Moving and Handle: the live edit was applied incrementally
            // in `on_move`, so the document is already up to date.
            State::Moving { .. } | State::Handle { .. } | State::Idle => {}
        }
    }

    fn draw_overlay(&self, model: &Model, ctx: &CanvasRenderingContext2d) {
        let doc = model.document();

        // Draw Bezier handles for selected path elements
        let sel_color = "rgb(0,120,255)";
        for es in &doc.selection {
            if let Some(Element::Path(pe)) = doc.get_element(&es.path) {
                let anchors = control_points(&Element::Path(pe.clone()));
                for (ai, &(ax, ay)) in anchors.iter().enumerate() {
                    let (h_in, h_out) = path_handle_positions(&pe.d, ai);
                    // Draw handle lines and circles
                    for h in [h_in, h_out].iter().flatten() {
                        ctx.set_stroke_style_str(sel_color);
                        ctx.set_line_width(1.0);
                        ctx.begin_path();
                        ctx.move_to(ax, ay);
                        ctx.line_to(h.0, h.1);
                        ctx.stroke();

                        ctx.set_fill_style_str("white");
                        ctx.set_stroke_style_str(sel_color);
                        ctx.begin_path();
                        ctx.arc(h.0, h.1, 3.0, 0.0, std::f64::consts::TAU).ok();
                        ctx.fill();
                        ctx.stroke();
                    }
                }
            }
        }

        // The Marquee state is the only one that needs an overlay —
        // the live edits in `Moving` and `Handle` already render the
        // updated element on the next frame.
        if let State::Marquee {
            start_x,
            start_y,
            cur_x,
            cur_y,
        } = &self.state
        {
            let rx = start_x.min(*cur_x);
            let ry = start_y.min(*cur_y);
            let rw = (cur_x - start_x).abs();
            let rh = (cur_y - start_y).abs();
            ctx.set_stroke_style_str("rgba(0, 120, 215, 0.8)");
            ctx.set_fill_style_str("rgba(0, 120, 215, 0.1)");
            ctx.set_line_width(1.0);
            ctx.fill_rect(rx, ry, rw, rh);
            ctx.stroke_rect(rx, ry, rw, rh);
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::document::document::{Document, SelectionKind, SortedCps};
    use crate::geometry::element::{
        Color, CommonProps, Fill, LayerElem, PolygonElem, RectElem,
    };

    fn make_model_with_rect() -> Model {
        // Rect at (0, 0) 10x10. Control-point indices and positions:
        //   0 = (0, 0)   top-left
        //   1 = (10, 0)  top-right
        //   2 = (10, 10) bottom-right
        //   3 = (0, 10)  bottom-left
        let rect = Element::Rect(RectElem {
            x: 0.0, y: 0.0, width: 10.0, height: 10.0, rx: 0.0, ry: 0.0,
            fill: Some(Fill::new(Color::BLACK)),
            stroke: None,
            common: CommonProps::default(),
        });
        let layer = Element::Layer(LayerElem {
            name: "L".to_string(),
            children: vec![std::rc::Rc::new(rect)],
            isolated_blending: false,
            knockout_group: false,
            common: CommonProps::default(),
        });
        let doc = Document {
            layers: vec![layer],
            selected_layer: 0,
            selection: Vec::new(),
         ..Document::default()};
        Model::new(doc, None)
    }

    #[test]
    fn click_unselected_cp_switches_selection_and_moves_only_that_cp() {
        // Regression: pressing on a different (unselected) CP of the
        // already-selected element used to fall through to the
        // "click on selected element bounds" branch and drag the
        // existing partial selection. The new behavior is to switch
        // the selection to the clicked CP and drag *that*.
        let mut tool = PartialSelectionTool::new();
        let mut model = make_model_with_rect();

        // Pre-select only CP 0 (top-left at 0,0).
        Controller::select_control_point(&mut model, &vec![0, 0], 0);
        let es = model.document().selection.first().unwrap();
        assert_eq!(es.kind, SelectionKind::Partial(SortedCps::from_iter([0])));

        // Press on CP 1 (top-right at 10,0) and drag it down by 5.
        // CP 1 is *not* in the selection — the press should switch
        // the selection to {1} and move only CP 1.
        tool.on_press(&mut model, 10.0, 0.0, false, false);
        tool.on_move(&mut model, 10.0, 5.0, false, false, true);
        tool.on_release(&mut model, 10.0, 5.0, false, false);

        // Selection should now be {1}, not {0}.
        let es = model.document().selection.first().unwrap();
        assert_eq!(
            es.kind,
            SelectionKind::Partial(SortedCps::from_iter([1])),
            "click on unselected CP should replace selection with that CP"
        );

        // The rect was converted to a polygon by the partial CP move.
        // CP 1 (top-right) should now be at (10, 5); CP 0 (top-left)
        // should be unchanged at (0, 0). If the old behavior had run,
        // CP 0 — the previously selected CP — would have moved instead.
        let layer = model.document().layers[0].children().unwrap();
        let elem = &*layer[0];
        match elem {
            Element::Polygon(PolygonElem { points, .. }) => {
                assert_eq!(points[0], (0.0, 0.0), "CP 0 should not have moved");
                assert_eq!(points[1], (10.0, 5.0), "CP 1 should have moved to (10, 5)");
                assert_eq!(points[2], (10.0, 10.0));
                assert_eq!(points[3], (0.0, 10.0));
            }
            other => panic!("expected Polygon after partial-CP move, got {:?}", other),
        }
    }

    #[test]
    fn click_already_selected_cp_drags_whole_selection() {
        // Companion to the test above: pressing on a CP that *is*
        // already in the selection drags the whole existing selection,
        // not just that CP. This is the "click an already-selected CP
        // and move all selected CPs together" gesture.
        let mut tool = PartialSelectionTool::new();
        let mut model = make_model_with_rect();

        // Select CPs 0 and 1 (both top corners).
        Controller::set_selection(
            &mut model,
            vec![ElementSelection {
                path: vec![0, 0],
                kind: SelectionKind::Partial(SortedCps::from_iter([0, 1])),
            }],
        );

        // Press on CP 0 — already in the selection — and drag down 5.
        // Both CPs 0 and 1 should move together.
        tool.on_press(&mut model, 0.0, 0.0, false, false);
        tool.on_move(&mut model, 0.0, 5.0, false, false, true);
        tool.on_release(&mut model, 0.0, 5.0, false, false);

        // Selection should still be {0, 1}.
        let es = model.document().selection.first().unwrap();
        assert_eq!(
            es.kind,
            SelectionKind::Partial(SortedCps::from_iter([0, 1])),
            "press on already-selected CP must preserve the existing selection"
        );

        let layer = model.document().layers[0].children().unwrap();
        match &*layer[0] {
            Element::Polygon(PolygonElem { points, .. }) => {
                assert_eq!(points[0], (0.0, 5.0), "CP 0 moved");
                assert_eq!(points[1], (10.0, 5.0), "CP 1 also moved");
                assert_eq!(points[2], (10.0, 10.0));
                assert_eq!(points[3], (0.0, 10.0));
            }
            other => panic!("expected Polygon, got {:?}", other),
        }
    }

    fn make_model_with_big_rect() -> Model {
        // Rect at (0,0) 100x100 — big enough that the center (50,50)
        // is well outside HIT_RADIUS (=8) of any corner.
        let rect = Element::Rect(RectElem {
            x: 0.0, y: 0.0, width: 100.0, height: 100.0, rx: 0.0, ry: 0.0,
            fill: Some(Fill::new(Color::BLACK)),
            stroke: None,
            common: CommonProps::default(),
        });
        let layer = Element::Layer(LayerElem {
            name: "L".to_string(),
            children: vec![std::rc::Rc::new(rect)],
            isolated_blending: false,
            knockout_group: false,
            common: CommonProps::default(),
        });
        let doc = Document {
            layers: vec![layer],
            selected_layer: 0,
            selection: Vec::new(),
         ..Document::default()};
        Model::new(doc, None)
    }

    #[test]
    fn press_inside_body_without_cp_hit_starts_marquee_not_move() {
        // With the Partial Selection tool, a press in empty space OR
        // inside the body/fill of a selected element (but not on a
        // CP) must start a new marquee selection, not drag the
        // existing selection.
        let mut tool = PartialSelectionTool::new();
        let mut model = make_model_with_big_rect();

        // Pre-select the whole rect (Partial with all CPs). The
        // press point (50,50) is the rect center, far from every
        // corner, so no CP hit-test will match.
        Controller::set_selection(
            &mut model,
            vec![ElementSelection {
                path: vec![0, 0],
                kind: SelectionKind::Partial(SortedCps::from_iter([0usize, 1, 2, 3])),
            }],
        );

        // Press at the rect's center.
        tool.on_press(&mut model, 50.0, 50.0, false, false);

        // Tool must now be in Marquee state, not Moving.
        match &tool.state {
            State::Marquee { .. } => {}
            other => panic!("expected Marquee, got {:?}", other),
        }

        // Drag a small marquee and release: because we pressed on
        // empty-ish space, the release with a tiny/no drag and no
        // shift must clear the selection (the existing empty-release
        // behavior of the marquee branch).
        tool.on_release(&mut model, 50.0, 50.0, false, false);
        assert!(
            model.document().selection.is_empty(),
            "click in body without CP hit should clear selection, got {:?}",
            model.document().selection
        );

        // And the rect must remain an unmodified Rect — in
        // particular not converted to a Polygon.
        let elem = &*model.document().layers[0].children().unwrap()[0];
        assert!(matches!(elem, Element::Rect(_)),
            "rect must stay a Rect, got {:?}", elem);
    }

    #[test]
    fn shift_click_last_selected_cp_leaves_partial_empty() {
        // Shift-toggling the single remaining CP must not drop the
        // element from the selection. Instead the element stays
        // selected with `Partial(empty)` — "selected, no CPs
        // individually highlighted".
        let mut tool = PartialSelectionTool::new();
        let mut model = make_model_with_rect();

        // Pre-select only CP 0.
        Controller::select_control_point(&mut model, &vec![0, 0], 0);

        // Shift-click on CP 0 again — removes it from the selection.
        tool.on_press(&mut model, 0.0, 0.0, /*shift=*/true, false);
        tool.on_release(&mut model, 0.0, 0.0, /*shift=*/true, false);

        // Element must still be in the selection, with kind = Partial(empty).
        let sel = &model.document().selection;
        assert_eq!(sel.len(), 1, "element must remain selected");
        assert_eq!(sel[0].path, vec![0, 0]);
        match &sel[0].kind {
            SelectionKind::Partial(s) => {
                assert!(s.is_empty(), "expected Partial(empty), got {:?}", s);
            }
            other => panic!("expected Partial(empty), got {:?}", other),
        }
    }
}
