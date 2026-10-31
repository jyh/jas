//! The SELECTION HIGHLIGHT, drawn through any [`Painter`] -- the outline of
//! each selected element and its control-point (anchor) squares.
//!
//! ⭐ WHY THIS EXISTS: the web canvas draws the highlight in
//! `canvas::render::draw_selection_overlays`, but the whole `canvas` module is
//! behind `feature = "web"`, so a native frame (`ffi_pointer::emit_frame`, the
//! WinUI shell's only picture) drew the document and the TOOL's overlay and
//! never the selection. Found by the first hand-test of the Windows app, 2026-10-10:
//! *"Anchor points do not show selection."*
//!
//! This is a port of that routine onto [`OverlayCtx`], call for call, so the
//! two draw the same thing: the same colour, the same fixed 1 px pen, the same
//! counter-scaled outline under the element transform, the same fixed-size
//! squares (`HANDLE_DRAW_SIZE`) under the view transform only, filled blue
//! when the control point is selected and white when it is not.
//! ⚠️ It is a SECOND COPY of the web routine, kept beside it deliberately so
//! the web pictures do not move. Folding the web path onto this one is the
//! port owner's call; until then a change to either must be made to both.

use crate::document::document::Document;
use crate::document::selection_geometry::{handle_zoom, selection_handle_rects_at_zoom, selection_outline_scale_at_zoom};
use crate::geometry::element::{Element, PathCommand};
use crate::painter::overlay_ctx::OverlayCtx;

/// The web routine's colour, verbatim.
const SEL_COLOR: &str = "rgba(0, 120, 215, 0.9)";

/// Draw the selection highlight for every selected element of `doc` -- the
/// port of `canvas::render::draw_selection_overlays`; see the module docs.
/// `zoom` is the view's: the anchor squares are a fixed screen size.
pub fn draw_selection_overlays(ctx: &mut OverlayCtx, doc: &Document, zoom: f64) {
    if doc.selection.is_empty() {
        return;
    }
    ctx.set_stroke_style_str(SEL_COLOR);
    ctx.set_line_width(1.0);

    // As on the web: one resolver for the whole pass, so a container holding a
    // symbol instance measures the instance's TARGET, not a phantom origin.
    let sel_index = crate::document::id_index::rebuild_id_index(doc);
    let sel_resolver = crate::document::id_index::IndexResolver(&sel_index);

    for es in &doc.selection {
        let Some(elem) = doc.get_element(&es.path) else { continue };

        // The outline is traced UNDER the element transform and the view, with
        // the pen counter-scaled by both so it stays 1 SCREEN px at every zoom
        // (finding 9's scope, like the squares); the squares below are drawn after
        // the transform is undone.
        // The FULL local-to-document frame, not only the element's own
        // transform: a child of a transformed group or wrapper is drawn under
        // its ancestors' frames too (route 4 slice 3b).
        let frame = crate::document::evaluated_bounds::accumulated_transform(doc, &es.path, true);
        let transformed = if let Some(t) = frame.as_ref() {
            ctx.transform(t);
            true
        } else {
            false
        };
        let outline_scale = selection_outline_scale_at_zoom(doc, &es.path, zoom);
        ctx.set_line_width(if outline_scale > 1e-6 { 1.0 / outline_scale } else { 1.0 });

        let is_text_like = matches!(elem, Element::Text(_) | Element::TextPath(_));
        let is_container = matches!(elem, Element::Group(_) | Element::Layer(_));
        if is_container {
            if let Some((bx, by, bw, bh)) = crate::geometry::element::resolved_bounds_with(
                elem, &sel_resolver, Element::bounds)
                && bw > 0.0
                && bh > 0.0
            {
                ctx.stroke_rect(bx, by, bw, bh);
            }
        } else if is_text_like {
            let (bx, by, bw, bh) = elem.bounds();
            if bw > 0.0 && bh > 0.0 {
                ctx.stroke_rect(bx, by, bw, bh);
            }
        } else {
            ctx.begin_path();
            trace_element_path(ctx, elem);
            ctx.stroke();
            ctx.begin_path();
        }
        if transformed {
            ctx.restore();
        }

        // Control-point squares: a FIXED SCREEN size (the rects and their
        // 1 px edge divided by the zoom), under the view transform only;
        // blue when the point is selected, white when not.
        ctx.set_line_width(1.0 / handle_zoom(zoom));
        ctx.set_stroke_style_str(SEL_COLOR);
        for (i, (hx, hy, hw, hh)) in selection_handle_rects_at_zoom(doc, &es.path, zoom).into_iter().enumerate() {
            ctx.set_fill_style_str(if es.kind.contains(i) { SEL_COLOR } else { "white" });
            ctx.fill_rect(hx, hy, hw, hh);
            ctx.stroke_rect(hx, hy, hw, hh);
        }
    }
}

/// The element's own path, for the outline -- `canvas::render::trace_element_path`
/// onto [`OverlayCtx`]. Smooth curves and arcs become a line to their end point,
/// exactly as the web `build_path` approximates them.
fn trace_element_path(ctx: &mut OverlayCtx, elem: &Element) {
    match elem {
        Element::Line(e) => {
            ctx.move_to(e.x1, e.y1);
            ctx.line_to(e.x2, e.y2);
        }
        Element::Rect(e) => {
            let (x, y, w, h) = (e.x, e.y, e.width, e.height);
            if e.rx > 0.0 || e.ry > 0.0 {
                let rx = e.rx.max(0.0).min(w / 2.0);
                let ry = e.ry.max(0.0).min(h / 2.0);
                ctx.move_to(x + rx, y);
                ctx.line_to(x + w - rx, y);
                ctx.quadratic_curve_to(x + w, y, x + w, y + ry);
                ctx.line_to(x + w, y + h - ry);
                ctx.quadratic_curve_to(x + w, y + h, x + w - rx, y + h);
                ctx.line_to(x + rx, y + h);
                ctx.quadratic_curve_to(x, y + h, x, y + h - ry);
                ctx.line_to(x, y + ry);
                ctx.quadratic_curve_to(x, y, x + rx, y);
                ctx.close_path();
            } else {
                // canvas `rect()`: a closed four-corner sub-path.
                ctx.move_to(x, y);
                ctx.line_to(x + w, y);
                ctx.line_to(x + w, y + h);
                ctx.line_to(x, y + h);
                ctx.close_path();
            }
        }
        Element::Ellipse(e) => {
            ctx.ellipse(e.cx, e.cy, e.rx, e.ry, 0.0, 0.0, std::f64::consts::TAU);
        }
        Element::Polyline(e) => poly(ctx, &e.points, false),
        Element::Polygon(e) => poly(ctx, &e.points, true),
        Element::Path(e) => {
            for cmd in &e.d {
                match *cmd {
                    PathCommand::MoveTo { x, y } => ctx.move_to(x, y),
                    PathCommand::LineTo { x, y } => ctx.line_to(x, y),
                    PathCommand::CurveTo { x1, y1, x2, y2, x, y } =>
                        ctx.bezier_curve_to(x1, y1, x2, y2, x, y),
                    PathCommand::QuadTo { x1, y1, x, y } => ctx.quadratic_curve_to(x1, y1, x, y),
                    PathCommand::ClosePath => ctx.close_path(),
                    PathCommand::SmoothCurveTo { x, y, .. }
                    | PathCommand::SmoothQuadTo { x, y }
                    | PathCommand::ArcTo { x, y, .. } => ctx.line_to(x, y),
                }
            }
        }
        Element::Text(_) | Element::TextPath(_) | Element::Group(_) | Element::Layer(_) => {}
        Element::Live(v) => {
            use crate::geometry::live::{LiveVariant, VisitSet, DEFAULT_PRECISION};
            let r = crate::document::id_index::InstalledResolver;
            let mut visiting = VisitSet::new();
            let ps = match v {
                LiveVariant::CompoundShape(cs) => cs.evaluate_with(DEFAULT_PRECISION, &r, &mut visiting),
                LiveVariant::Reference(x) => x.evaluate_with(DEFAULT_PRECISION, &r, &mut visiting),
                LiveVariant::Recorded(x) => x.evaluate_with(DEFAULT_PRECISION, &r, &mut visiting),
                LiveVariant::Generated(x) => x.evaluate_with(DEFAULT_PRECISION, &r, &mut visiting),
                LiveVariant::Transformed(x) => x.evaluate_with(DEFAULT_PRECISION, &r, &mut visiting),
            };
            for ring in &ps {
                if ring.len() < 2 { continue; }
                poly(ctx, ring, true);
            }
        }
    }
}

fn poly(ctx: &mut OverlayCtx, points: &[(f64, f64)], close: bool) {
    let Some(&(x0, y0)) = points.first() else { return };
    ctx.move_to(x0, y0);
    for &(x, y) in &points[1..] {
        ctx.line_to(x, y);
    }
    if close {
        ctx.close_path();
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::document::document::ElementSelection;
    use crate::document::test_fixture::{group, model_with, rect};
    use crate::geometry::element::Color;
    use crate::painter::recording::{Command, RecordingPainter};
    use crate::painter::Brush;
    use crate::tool_consts::HANDLE_DRAW_SIZE;

    fn drawn(doc: &Document) -> Vec<Command> {
        drawn_at(doc, 1.0)
    }

    fn drawn_at(doc: &Document, zoom: f64) -> Vec<Command> {
        let mut rec = RecordingPainter::new();
        {
            let mut ctx = OverlayCtx::new(&mut rec);
            draw_selection_overlays(&mut ctx, doc, zoom);
            ctx.finish();
        }
        rec.commands().to_vec()
    }

    fn blue() -> Color {
        crate::painter::overlay_ctx::css_color("rgba(0, 120, 215, 0.9)").unwrap()
    }

    fn fills(cmds: &[Command]) -> Vec<(f64, f64, f64, f64, Color)> {
        cmds.iter().filter_map(|c| match c {
            Command::FillRect { rect, brush: Brush::Solid(col), .. } =>
                Some((rect.x, rect.y, rect.w, rect.h, *col)),
            _ => None,
        }).collect()
    }

    /// A 100x80 rect at (20,30), selected whole: its outline, and a filled
    /// square at each of its four corners.
    #[test]
    fn a_whole_selected_rect_shows_four_filled_anchor_squares() {
        let m = model_with(vec![rect(20.0, 30.0, 100.0, 80.0)], &[0]);
        let cmds = drawn(m.document());
        let f = fills(&cmds);
        assert_eq!(f.len(), 4, "one square per corner: {cmds:?}");
        let h = HANDLE_DRAW_SIZE / 2.0;
        let mut centres: Vec<(f64, f64)> = f.iter().map(|q| (q.0 + h, q.1 + h)).collect();
        centres.sort_by(|a, b| a.partial_cmp(b).unwrap());
        assert_eq!(centres, vec![(20.0, 30.0), (20.0, 110.0), (120.0, 30.0), (120.0, 110.0)]);
        for q in &f {
            assert_eq!((q.2, q.3), (HANDLE_DRAW_SIZE, HANDLE_DRAW_SIZE), "a fixed-size square");
            assert_eq!(q.4, blue(), "every point of a WHOLE selection is selected");
        }
        let edged = cmds.iter().filter(|c| matches!(c, Command::StrokeRect { .. })).count();
        assert_eq!(edged, 4, "each square is also edged");
        assert!(cmds.iter().any(|c| matches!(c, Command::StrokePath { .. })),
                "the element's own outline is traced");
    }

    /// Finding 9's scope, ruled 2026-10-31 (STATUS-flask 692): the OUTLINE is
    /// selection chrome too, so its pen is 1 SCREEN px at every zoom. Drawn
    /// under the view transform that is `1 / z` document units. Before this the
    /// pen was 1 document unit, so the edge band grew with the zoom (flask
    /// measured 7 px at 3.75x and 16 px at 7.8x on the Windows box).
    #[test]
    fn the_outline_is_one_screen_pixel_at_every_zoom() {
        let m = model_with(vec![rect(20.0, 30.0, 100.0, 80.0)], &[0]);
        for z in [0.25, 1.0, 2.0, 3.75, 7.8] {
            let pens: Vec<f64> = drawn_at(m.document(), z).iter().filter_map(|c| match c {
                Command::StrokePath { stroke, .. } => Some(stroke.width),
                _ => None,
            }).collect();
            assert_eq!(pens.len(), 1, "zoom {z}: one outline trace");
            assert!((pens[0] * z - 1.0).abs() < 1e-9, "zoom {z}: pen {}", pens[0]);
        }
    }

    /// THE CAPTAIN'S RULING, 10-30 feel sitting (finding 9): the squares are a
    /// FIXED SCREEN SIZE. Drawn under the view transform, a square at zoom z
    /// is `HANDLE_DRAW_SIZE / z` document units, so it shows the same size at
    /// every zoom; its centre does not move, and zoom 1 is the old picture.
    #[test]
    fn the_anchor_squares_are_a_fixed_screen_size_at_every_zoom() {
        let m = model_with(vec![rect(20.0, 30.0, 100.0, 80.0)], &[0]);
        let at_one = fills(&drawn(m.document()));
        assert_eq!(fills(&drawn_at(m.document(), 1.0)), at_one);
        for z in [0.25, 0.5, 2.0, 4.0] {
            let f = fills(&drawn_at(m.document(), z));
            assert_eq!(f.len(), 4, "zoom {z}");
            for (q, q1) in f.iter().zip(at_one.iter()) {
                assert!((q.2 * z - HANDLE_DRAW_SIZE).abs() < 1e-9, "zoom {z}: {q:?}");
                assert!((q.3 * z - HANDLE_DRAW_SIZE).abs() < 1e-9, "zoom {z}: {q:?}");
                assert!((q.0 + q.2 / 2.0 - (q1.0 + q1.2 / 2.0)).abs() < 1e-9
                        && (q.1 + q.3 / 2.0 - (q1.1 + q1.3 / 2.0)).abs() < 1e-9,
                        "zoom {z} moved a centre: {q:?} vs {q1:?}");
            }
        }
        // Not a view: drawn at zoom 1, never divided by zero.
        for z in [0.0, -2.0, f64::NAN] {
            assert_eq!(fills(&drawn_at(m.document(), z)), at_one, "zoom {z}");
        }
    }

    /// A PARTIAL selection fills only the chosen anchor; the rest are white.
    #[test]
    fn a_partial_selection_fills_only_its_chosen_anchor() {
        let mut m = model_with(vec![rect(20.0, 30.0, 100.0, 80.0)], &[]);
        let mut doc = m.document().clone();
        doc.selection = vec![ElementSelection::partial(vec![0, 0], [2])];
        m.set_document_for_test(doc);
        let f = fills(&drawn(m.document()));
        assert_eq!(f.len(), 4);
        let white = Color::new(1.0, 1.0, 1.0, 1.0);
        assert_eq!(f.iter().filter(|q| q.4 == blue()).count(), 1, "{f:?}");
        assert_eq!(f.iter().filter(|q| q.4 == white).count(), 3, "{f:?}");
    }

    /// A WRAPPED CHILD (`[0, 0, 0]` inside a scale(2,3) Transformed wrapper)
    /// is highlighted where it is DRAWN: its squares sit on the mapped corners,
    /// and its outline is traced under the frame `W·M` the wrapper gives it.
    /// Before route 4 slice 3b the path did not resolve and nothing was drawn.
    #[test]
    fn a_wrapped_childs_highlight_sits_where_the_child_is_drawn() {
        use crate::geometry::element::Transform;
        use crate::geometry::live::{LiveVariant, TransformedElem};
        let w = TransformedElem::new(std::rc::Rc::new(rect(2.0, 2.0, 10.0, 10.0)), Transform::scale(2.0, 3.0), false);
        let mut m = model_with(vec![Element::Live(LiveVariant::Transformed(w))], &[]);
        let mut doc = m.document().clone();
        doc.selection = vec![ElementSelection::partial(vec![0, 0, 0], [2])];
        m.set_document_for_test(doc);
        let cmds = drawn(m.document());
        let h = HANDLE_DRAW_SIZE / 2.0;
        let mut centres: Vec<(f64, f64)> = fills(&cmds).iter().map(|q| (q.0 + h, q.1 + h)).collect();
        centres.sort_by(|a, b| a.partial_cmp(b).unwrap());
        assert_eq!(centres, vec![(4.0, 6.0), (4.0, 36.0), (24.0, 6.0), (24.0, 36.0)], "{cmds:?}");
        let pushed: Vec<Transform> = cmds.iter().filter_map(|c| match c {
            Command::PushState { transform } => Some(*transform),
            _ => None,
        }).collect();
        assert_eq!(pushed, vec![Transform::scale(2.0, 3.0)], "the outline is traced under W·M");
        assert!(cmds.iter().any(|c| matches!(c, Command::StrokePath { .. })));
    }

    /// A selected GROUP is one box around its contents, with no squares.
    #[test]
    fn a_selected_group_is_one_box_and_no_squares() {
        let g = group(vec![rect(0.0, 0.0, 10.0, 10.0), rect(30.0, 40.0, 10.0, 10.0)]);
        let m = model_with(vec![g], &[0]);
        let cmds = drawn(m.document());
        assert!(fills(&cmds).is_empty(), "{cmds:?}");
        let boxes: Vec<_> = cmds.iter().filter_map(|c| match c {
            Command::StrokeRect { rect, .. } => Some((rect.x, rect.y, rect.w, rect.h)),
            _ => None,
        }).collect();
        assert_eq!(boxes, vec![(0.0, 0.0, 40.0, 50.0)]);
    }

    /// Nothing selected draws nothing, so an unselected frame is unchanged.
    #[test]
    fn nothing_selected_draws_nothing() {
        let m = model_with(vec![rect(20.0, 30.0, 100.0, 80.0)], &[]);
        assert!(drawn(m.document()).is_empty());
    }
}
