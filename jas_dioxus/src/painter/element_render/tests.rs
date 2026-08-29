//! The R4 display-list-equivalence gate for the PH1 element surface.
//!
//! A small set of REFERENCE DOCUMENTS — built in code from the document model —
//! render through [`emit_element`](super::emit_element) into a
//! [`RecordingPainter`], and each is asserted against a committed golden under
//! `testdata/ref_*.json`. These goldens are the behavior-lock the production
//! conversion lands behind (contract R4). Floats obey the R7 doc-space
//! 4-decimal round-half-even law; the whole frame rides ONE view transform
//! pushed as a matrix (D2), so paint coordinates stay in document space.
//!
//! Regenerate after a deliberate reference-doc change:
//! `cargo test -p jas_dioxus regenerate_reference_goldens -- --ignored`.

use super::{
    element_needs_legacy, ellipse_painter_inputs, emit_element,
    emit_shape_paint, line_painter_inputs, path_painter_inputs, polygon_painter_inputs,
    polyline_painter_inputs, rect_painter_inputs, ConvGeom, ShapePaint,
};
use crate::painter::recording::Command;
use crate::geometry::element::{
    Arrowhead, Color, CommonProps, Element, EllipseElem, Fill, FillRule, Gradient,
    GradientStop, GradientType, GroupElem, LineElem, PathCommand, PathElem, PolygonElem,
    PolylineElem, RectElem, Stroke, StrokeAlign, StrokeWidthPoint, Transform,
};
use crate::painter::recording::RecordingPainter;
use crate::painter::Painter;
use std::rc::Rc;

// ---------------------------------------------------------------------------
// Small constructors (keep the reference docs readable)
// ---------------------------------------------------------------------------

fn common() -> CommonProps {
    CommonProps::default()
}

fn common_alpha(opacity: f64) -> CommonProps {
    CommonProps { opacity, ..CommonProps::default() }
}

fn fill(color: Color) -> Option<Fill> {
    Some(Fill { color, opacity: 1.0 })
}

fn fill_op(color: Color, opacity: f64) -> Option<Fill> {
    Some(Fill { color, opacity })
}

fn stroke(color: Color, width: f64) -> Stroke {
    Stroke::new(color, width)
}

fn stroke_aligned(color: Color, width: f64, align: StrokeAlign) -> Stroke {
    let mut s = Stroke::new(color, width);
    s.align = align;
    s
}

fn linear_grad(angle: f64) -> Box<Gradient> {
    Box::new(Gradient {
        gtype: GradientType::Linear,
        angle,
        aspect_ratio: 100.0,
        stops: vec![
            GradientStop { color: Color::rgb(1.0, 0.0, 0.0), opacity: 100.0, location: 0.0, midpoint_to_next: 50.0 },
            GradientStop { color: Color::rgb(0.0, 0.0, 1.0), opacity: 80.0, location: 100.0, midpoint_to_next: 50.0 },
        ],
        ..Gradient::default()
    })
}

fn radial_grad() -> Box<Gradient> {
    Box::new(Gradient {
        gtype: GradientType::Radial,
        angle: 0.0,
        aspect_ratio: 100.0,
        stops: vec![
            GradientStop { color: Color::WHITE, opacity: 100.0, location: 0.0, midpoint_to_next: 50.0 },
            GradientStop { color: Color::BLACK, opacity: 100.0, location: 100.0, midpoint_to_next: 50.0 },
        ],
        ..Gradient::default()
    })
}

fn rect(x: f64, y: f64, w: f64, h: f64, f: Option<Fill>, s: Option<Stroke>) -> Element {
    Element::Rect(RectElem {
        x, y, width: w, height: h, rx: 0.0, ry: 0.0,
        fill: f, stroke: s, common: common(),
        fill_gradient: None, stroke_gradient: None,
    })
}

// ---------------------------------------------------------------------------
// Reference documents
// ---------------------------------------------------------------------------

/// Filled + stroked rects (plain and rounded), a circle and an ellipse
/// (fill-then-stroke), and a line.
fn ref_shapes() -> Vec<Element> {
    let blue = Color::rgb(0.2, 0.4, 0.8);
    let red = Color::rgb(0.9, 0.3, 0.1);
    vec![
        rect(10.0, 20.0, 100.0, 60.0, fill(blue), Some(stroke(Color::BLACK, 2.0))),
        Element::Rect(RectElem {
            x: 130.0, y: 20.0, width: 80.0, height: 50.0, rx: 12.0, ry: 8.0,
            fill: fill_op(red, 0.75), stroke: Some(stroke(Color::BLACK, 3.0)),
            common: common(), fill_gradient: None, stroke_gradient: None,
        }),
        Element::Ellipse(EllipseElem {
            cx: 260.0, cy: 60.0, rx: 40.0, ry: 40.0,
            fill: fill(red), stroke: Some(stroke(Color::BLACK, 2.0)),
            common: common(), fill_gradient: None, stroke_gradient: None,
        }),
        Element::Ellipse(EllipseElem {
            cx: 380.0, cy: 60.0, rx: 50.0, ry: 30.0,
            fill: fill(blue), stroke: Some(stroke(Color::rgb(0.1, 0.1, 0.1), 1.5)),
            common: common(), fill_gradient: None, stroke_gradient: None,
        }),
        Element::Line(LineElem {
            x1: 20.0, y1: 120.0, x2: 200.0, y2: 160.0,
            stroke: Some(stroke(Color::rgb(0.0, 0.5, 0.0), 4.0)),
            width_points: vec![], common: common(), stroke_gradient: None,
        }),
    ]
}

/// A bezier path, a quad path, a polygon (fill+stroke), and a polyline.
fn ref_paths() -> Vec<Element> {
    let green = Color::rgb(0.2, 0.6, 0.3);
    let bezier = PathElem {
        d: vec![
            PathCommand::MoveTo { x: 20.0, y: 200.0 },
            PathCommand::CurveTo { x1: 60.0, y1: 120.0, x2: 140.0, y2: 280.0, x: 180.0, y: 200.0 },
            PathCommand::ClosePath,
        ],
        fill: fill(green),
        stroke: Some(stroke(Color::BLACK, 2.0)),
        common: common(),
        ..PathElem::default()
    };
    let quad = PathElem {
        d: vec![
            PathCommand::MoveTo { x: 220.0, y: 200.0 },
            PathCommand::QuadTo { x1: 260.0, y1: 140.0, x: 300.0, y: 200.0 },
        ],
        fill: None,
        stroke: Some(stroke(Color::rgb(0.5, 0.0, 0.5), 3.0)),
        common: common(),
        ..PathElem::default()
    };
    let polygon = Element::Polygon(PolygonElem {
        points: vec![(340.0, 180.0), (400.0, 180.0), (380.0, 240.0), (350.0, 230.0)],
        fill: fill_op(green, 0.6),
        stroke: Some(stroke(Color::BLACK, 2.0)),
        common: common(),
        fill_gradient: None,
        stroke_gradient: None,
    });
    let polyline = Element::Polyline(PolylineElem {
        points: vec![(420.0, 200.0), (450.0, 160.0), (480.0, 210.0), (510.0, 170.0)],
        fill: None,
        stroke: Some(stroke(Color::rgb(0.8, 0.4, 0.0), 2.5)),
        common: common(),
        fill_gradient: None,
        stroke_gradient: None,
    });
    vec![Element::Path(bezier), Element::Path(quad), polygon, polyline]
}

/// Solid vs linear/radial gradient brushes (resolved endpoints cross the seam).
fn ref_gradients() -> Vec<Element> {
    vec![
        Element::Rect(RectElem {
            x: 10.0, y: 10.0, width: 120.0, height: 80.0, rx: 0.0, ry: 0.0,
            fill: fill(Color::WHITE), stroke: None,
            common: common(), fill_gradient: Some(linear_grad(30.0)), stroke_gradient: None,
        }),
        Element::Ellipse(EllipseElem {
            cx: 220.0, cy: 60.0, rx: 50.0, ry: 50.0,
            fill: fill(Color::WHITE), stroke: None,
            common: common(), fill_gradient: Some(radial_grad()), stroke_gradient: None,
        }),
        Element::Rect(RectElem {
            x: 300.0, y: 10.0, width: 120.0, height: 80.0, rx: 0.0, ry: 0.0,
            fill: None, stroke: Some(stroke(Color::BLACK, 6.0)),
            common: common(), fill_gradient: None, stroke_gradient: Some(linear_grad(90.0)),
        }),
    ]
}

/// A dashed line and inside/outside stroke alignment (build-time clip lowering).
fn ref_stroke_styles() -> Vec<Element> {
    let mut dashed = stroke(Color::rgb(0.1, 0.1, 0.1), 3.0);
    dashed.dash_pattern[0] = 8.0;
    dashed.dash_pattern[1] = 4.0;
    dashed.dash_len = 2;
    let dashed_line = Element::Line(LineElem {
        x1: 20.0, y1: 20.0, x2: 200.0, y2: 20.0,
        stroke: Some(dashed), width_points: vec![], common: common(), stroke_gradient: None,
    });
    let inside = PathElem {
        d: super::rounded_rect_path(40.0, 60.0, 80.0, 50.0, 0.0, 0.0),
        fill: fill(Color::rgb(0.7, 0.7, 0.9)),
        stroke: Some(stroke_aligned(Color::BLACK, 6.0, StrokeAlign::Inside)),
        common: common(),
        ..PathElem::default()
    };
    let outside = PathElem {
        d: super::rounded_rect_path(160.0, 60.0, 80.0, 50.0, 0.0, 0.0),
        fill: fill(Color::rgb(0.9, 0.7, 0.7)),
        stroke: Some(stroke_aligned(Color::BLACK, 6.0, StrokeAlign::Outside)),
        common: common(),
        ..PathElem::default()
    };
    vec![dashed_line, Element::Path(inside), Element::Path(outside)]
}

/// Nested groups with non-isolated alpha: an outer group at 0.5 wrapping an
/// inner group at 0.8 wrapping two OVERLAPPING filled rects — the overlaps
/// compound because the alpha folds per-primitive (contract PIN). A transform
/// on the outer group rides one matrix (D2).
fn ref_groups() -> Vec<Element> {
    let red = Color::rgb(0.9, 0.2, 0.2);
    let blue = Color::rgb(0.2, 0.2, 0.9);
    let inner = Element::Group(GroupElem {
        children: vec![
            Rc::new(rect(30.0, 30.0, 60.0, 60.0, fill(red), None)),
            Rc::new(rect(60.0, 60.0, 60.0, 60.0, fill(blue), None)),
        ],
        common: common_alpha(0.8),
        isolated_blending: false,
        knockout_group: false,
    });
    let outer = Element::Group(GroupElem {
        children: vec![Rc::new(inner)],
        common: CommonProps {
            opacity: 0.5,
            transform: Some(Transform { a: 1.0, b: 0.0, c: 0.0, d: 1.0, e: 200.0, f: 10.0 }),
            ..CommonProps::default()
        },
        isolated_blending: false,
        knockout_group: false,
    });
    vec![outer]
}

// ---------------------------------------------------------------------------
// The render harness + golden machinery
// ---------------------------------------------------------------------------

/// Render a reference document under one view transform (D2) and return its
/// canonical JSON.
fn render_doc(elems: &[Element]) -> String {
    let mut rec = RecordingPainter::new();
    // The driver owns the view transform and pushes it as ONE matrix (D2).
    rec.push_state(Transform { a: 1.5, b: 0.0, c: 0.0, d: 1.5, e: 20.0, f: 10.0 });
    for e in elems {
        // The capability router keeps legacy-only elements off the seam.
        if !element_needs_legacy(e) {
            emit_element(&mut rec, e, 1.0);
        }
    }
    rec.pop_state();
    let mut json = rec.to_canonical_json();
    json.push('\n');
    json
}

/// Each `(name, builder)` pair — one golden file per reference document.
fn reference_docs() -> Vec<(&'static str, Vec<Element>)> {
    vec![
        ("ref_shapes", ref_shapes()),
        ("ref_paths", ref_paths()),
        ("ref_gradients", ref_gradients()),
        ("ref_stroke_styles", ref_stroke_styles()),
        ("ref_groups", ref_groups()),
    ]
}

fn golden_path(name: &str) -> String {
    format!("{}/src/painter/testdata/{}.json", env!("CARGO_MANIFEST_DIR"), name)
}

/// The Painter op the production `render.rs` Line arm emits for the fixed
/// convertible line below, recorded canonically. Shared by the gate test and
/// the regenerator so they cannot drift.
fn render_line_convert() -> String {
    let e = LineElem {
        x1: 12.0, y1: 18.0, x2: 140.0, y2: 90.0,
        stroke: Some(stroke(Color::rgb(0.0, 0.5, 0.0), 4.0)),
        width_points: vec![],
        common: common(),
        stroke_gradient: None,
    };
    let lp = line_painter_inputs(&e).expect("convertible");
    let base_alpha = 1.0_f64;
    let mut rec = RecordingPainter::new();
    rec.stroke_path(&lp.path, &lp.brush, &lp.stroke, base_alpha * lp.stroke_op);
    let mut json = rec.to_canonical_json();
    json.push('\n');
    json
}

/// ON-DEMAND regenerator — rewrites every committed golden. Ignored so it never
/// runs in normal CI.
#[test]
#[ignore = "regeneration tool, not a gate"]
fn regenerate_reference_goldens() {
    for (name, doc) in reference_docs() {
        let json = render_doc(&doc);
        let path = golden_path(name);
        std::fs::write(&path, json).expect("write golden");
        eprintln!("wrote {path}");
    }
    let path = golden_path("ref_line_convert");
    std::fs::write(&path, render_line_convert()).expect("write line-convert golden");
    eprintln!("wrote {path}");
    for (name, sp, alpha) in convert_cases() {
        let path = golden_path(name);
        std::fs::write(&path, record_convert(&sp, alpha)).expect("write convert golden");
        eprintln!("wrote {path}");
    }
}

/// Every reference document serializes to exactly its committed golden.
#[test]
fn reference_docs_match_goldens() {
    for (name, doc) in reference_docs() {
        let json = render_doc(&doc);
        let golden = std::fs::read_to_string(golden_path(name))
            .unwrap_or_else(|_| panic!("missing golden {name}; run regenerate_reference_goldens"));
        assert_eq!(
            json.trim(),
            golden.trim(),
            "reference doc {name} diverged from its committed golden.\n--- got ---\n{json}\n--- end ---"
        );
    }
}

/// The render is deterministic (no emitter nondeterminism).
#[test]
fn reference_docs_are_deterministic() {
    for (name, doc) in reference_docs() {
        assert_eq!(render_doc(&doc), render_doc(&doc), "{name} nondeterministic");
    }
}

// ---------------------------------------------------------------------------
// Capability router + the byte-identical Line helper
// ---------------------------------------------------------------------------

// ---------------------------------------------------------------------------
// AMENDMENT A6 — the element bracket, produced from a DOCUMENT
// ---------------------------------------------------------------------------

/// A masked rect: own opacity 0.5, standard opacity mask (clip, not inverted),
/// mask artwork a white rect. Built here rather than in a shared fixture so the
/// numbers the assertions below name are visible beside them.
fn masked_rect(clip: bool, invert: bool) -> Element {
    use crate::geometry::element::Mask;
    let mut r = rect(10.0, 10.0, 40.0, 40.0, fill(Color::rgb(0.9, 0.2, 0.2)), None);
    if let Element::Rect(e) = &mut r {
        e.common.opacity = 0.5;
        e.common.mask = Some(Box::new(Mask {
            subtree: Box::new(rect(20.0, 20.0, 20.0, 20.0, fill(Color::WHITE), None)),
            clip,
            invert,
            disabled: false,
            linked: true,
            unlink_transform: None,
        }));
    }
    r
}

fn ops(elem: &Element, incoming: f64) -> Vec<Command> {
    let mut rec = RecordingPainter::new();
    emit_element(&mut rec, elem, incoming);
    rec.commands().to_vec()
}

/// ⛔ THE BRACKET, ASSERTED FROM THE CONTRACT — not captured from HEAD.
///
/// A6 §3.2 fixes the shape; §6.2 fixes the alpha law. Both are asserted here on
/// an op list produced by a real document element, which is what §6.2's
/// scene-level golden could not have: a PRODUCER.
#[test]
fn a6_masked_element_emits_the_bracket() {
    use crate::painter::Mask as PMask;
    let got = ops(&masked_rect(true, false), 1.0);

    // 1. THE GRAMMAR. Exactly one isolated layer, exactly one mask bracket
    //    inside it, and NOTHING between pop_mask_layer and pop_isolated_layer.
    assert!(matches!(got.first(), Some(Command::PushIsolatedLayer { .. })),
            "the bracket must OPEN the emission, got {:?}", got.first());
    assert!(matches!(got.last(), Some(Command::PopIsolatedLayer)),
            "the bracket must CLOSE the emission, got {:?}", got.last());
    let n = got.len();
    assert!(matches!(got[n - 2], Command::PopMaskLayer),
            "nothing may paint between pop_mask_layer and pop_isolated_layer (§3.2)");

    // 2. THE ALPHA LAW (§6.2, defect D-α). The element's own opacity rides the
    //    LAYER and is spent ONCE; the body must NOT carry it as well.
    match &got[0] {
        Command::PushIsolatedLayer { alpha, .. } =>
            assert_eq!(*alpha, 0.5, "the layer carries the element's OWN opacity"),
        c => panic!("expected PushIsolatedLayer, got {c:?}"),
    }
    let body: Vec<_> = got.iter()
        .filter(|c| matches!(c, Command::FillRect { .. }))
        .collect();
    assert_eq!(body.len(), 2, "one body fill + one mask-artwork fill");
    match body[0] {
        Command::FillRect { paint_alpha, .. } => assert_eq!(
            *paint_alpha, 1.0,
            "D-α: the body paints at the INCOMING alpha (1.0 here). 0.25 would \
             be the squared defect; 0.5 would be own-opacity applied twice."),
        c => panic!("expected FillRect, got {c:?}"),
    }
    // 3. The mask artwork is itself isolated at alpha context 1.0 (§3.2).
    match body[1] {
        Command::FillRect { paint_alpha, .. } =>
            assert_eq!(*paint_alpha, 1.0, "the mask bracket is isolated at 1.0"),
        c => panic!("expected FillRect, got {c:?}"),
    }
    // 4. THE LAW, from the ONE truth table: (clip, !invert) -> LuminanceClipIn.
    let law = got.iter().find_map(|c| match c {
        Command::PushMaskLayer { mask } => Some(*mask),
        _ => None,
    });
    assert_eq!(law, Some(PMask::LuminanceClipIn));
}

/// ⛔ THE INCOMING ALPHA IS DISCRIMINATING, and 0.5/0.5 is NOT — the squared
/// defect and the correct law both give 0.25 there, which is the same trap
/// `render.rs`'s own D-α test documents. So this drives 1.0 × 0.5 and 0.25 × 0.5.
#[test]
fn a6_masked_body_carries_ancestors_and_the_layer_carries_own_opacity() {
    for incoming in [1.0_f64, 0.25, 0.8] {
        let got = ops(&masked_rect(true, false), incoming);
        let layer = got.iter().find_map(|c| match c {
            Command::PushIsolatedLayer { alpha, .. } => Some(*alpha),
            _ => None,
        }).expect("a layer");
        let first_fill = got.iter().find_map(|c| match c {
            Command::FillRect { paint_alpha, .. } => Some(*paint_alpha),
            _ => None,
        }).expect("a body fill");
        assert_eq!(layer, 0.5, "own opacity, never the ancestors");
        assert_eq!(first_fill, incoming, "ancestors, never the own opacity");
        // The net the artist sees: each factor exactly ONCE.
        assert_eq!(layer * first_fill, 0.5 * incoming);

        // ⛔ AND THE MASK ARTWORK STAYS AT 1.0 **AT A NON-UNIT INCOMING**. The
        // first version of this suite asserted the artwork's alpha only at
        // incoming = 1.0, where "1.0" and "incoming" are the same number — so a
        // mutant that fed the ancestors into the mask bracket SURVIVED. The
        // mask bracket is isolated (§3.2); ancestor alpha must not reach it, and
        // that is only visible where the two values differ.
        let artwork = got.iter().filter_map(|c| match c {
            Command::FillRect { paint_alpha, .. } => Some(*paint_alpha),
            _ => None,
        }).nth(1).expect("the mask artwork fill");
        assert_eq!(artwork, 1.0,
                   "the mask bracket is isolated at alpha 1.0, whatever the \
                    ancestors carry (incoming={incoming})");
    }
}

/// The reveal law needs a bbox, and a backend never computes bounds (§3.3) —
/// so the producer must pass the MASK SUBTREE's bounds. The artwork here is a
/// 20×20 rect at (20, 20).
#[test]
fn a6_reveal_law_carries_the_mask_subtree_bbox() {
    use crate::painter::Mask as PMask;
    let got = ops(&masked_rect(false, false), 1.0);
    let law = got.iter().find_map(|c| match c {
        Command::PushMaskLayer { mask } => Some(*mask),
        _ => None,
    }).expect("a mask layer");
    match law {
        PMask::AlphaRevealOutsideBbox { bbox } => {
            assert_eq!((bbox.x, bbox.y, bbox.w, bbox.h), (20.0, 20.0, 20.0, 20.0),
                       "the bbox is the MASK SUBTREE's bounds, computed here");
        }
        other => panic!("(clip:false, invert:false) lowers to reveal, got {other:?}"),
    }
}

/// `(clip:false, invert:true)` COLLAPSES onto `(true, true)` — A6 §4 says so and
/// the truth table implements it. Pinned through the PRODUCER, not just the table.
#[test]
fn a6_invert_collapses_through_the_producer() {
    use crate::painter::Mask as PMask;
    for clip in [true, false] {
        let got = ops(&masked_rect(clip, true), 1.0);
        let law = got.iter().find_map(|c| match c {
            Command::PushMaskLayer { mask } => Some(*mask),
            _ => None,
        });
        assert_eq!(law, Some(PMask::AlphaClipOut),
                   "invert lowers to AlphaClipOut whatever `clip` says (clip={clip})");
    }
}

/// A DISABLED mask is not a mask: the element renders as if none were attached,
/// and no bracket is emitted at all. Legacy agrees (`mask_plan` returns None).
#[test]
fn a6_disabled_mask_emits_no_bracket() {
    let mut e = masked_rect(true, false);
    if let Element::Rect(r) = &mut e {
        r.common.mask.as_mut().unwrap().disabled = true;
    }
    let got = ops(&e, 1.0);
    assert!(!got.iter().any(|c| matches!(c, Command::PushIsolatedLayer { .. })),
            "a disabled mask must not open a layer, got {got:?}");
    // ...and the body then carries its OWN opacity again, the ordinary fold.
    match got.first() {
        Some(Command::FillRect { paint_alpha, .. }) => assert_eq!(*paint_alpha, 0.5),
        c => panic!("expected a bare body fill, got {c:?}"),
    }
}

/// ⛔ AND IT STILL DOES, WITH A PRODUCER SITTING RIGHT THERE. The bracket tests
/// above prove `emit_element` emits A6's element bracket for this same shape —
/// but `Canvas2dPainter::push_mask_layer` is `unimplemented!()`, so routing
/// production at it would panic. The producer and the routing are two steps and
/// this is the pin that keeps them apart until the PH4 backend lands.
#[test]
fn masked_element_needs_legacy() {
    use crate::geometry::element::Mask;
    let mut r = rect(0.0, 0.0, 10.0, 10.0, fill(Color::BLACK), None);
    assert!(!element_needs_legacy(&r), "plain rect converts");
    if let Element::Rect(e) = &mut r {
        e.common.mask = Some(Box::new(Mask {
            subtree: Box::new(rect(0.0, 0.0, 10.0, 10.0, fill(Color::WHITE), None)),
            clip: false,
            invert: false,
            disabled: false,
            linked: true,
            unlink_transform: None,
        }));
    }
    assert!(element_needs_legacy(&r), "an active mask forces the legacy path");
}

#[test]
fn freeform_gradient_needs_legacy() {
    let mut e = RectElem {
        x: 0.0, y: 0.0, width: 10.0, height: 10.0, rx: 0.0, ry: 0.0,
        fill: fill(Color::WHITE), stroke: None,
        common: common(), fill_gradient: None, stroke_gradient: None,
    };
    e.fill_gradient = Some(Box::new(Gradient { gtype: GradientType::Freeform, ..Gradient::default() }));
    assert!(element_needs_legacy(&Element::Rect(e)), "freeform gradient stays legacy");
}

#[test]
fn groups_and_shapes_do_not_need_legacy() {
    // Sanity: nested groups and plain shapes route through the seam.
    for (_name, doc) in reference_docs() {
        for e in &doc {
            assert!(!element_needs_legacy(e), "reference-doc element should convert");
        }
    }
}

#[test]
fn plain_line_is_painter_convertible() {
    let e = LineElem {
        x1: 5.0, y1: 6.0, x2: 100.0, y2: 40.0,
        stroke: Some(stroke(Color::rgb(0.0, 0.5, 0.0), 3.0)),
        width_points: vec![],
        common: common(),
        stroke_gradient: None,
    };
    let lp = line_painter_inputs(&e).expect("plain solid center line converts");
    assert_eq!(lp.path.len(), 2);
    assert_eq!(lp.stroke.width, 3.0);
    assert_eq!(lp.stroke_op, 1.0);
    assert!(matches!(lp.brush, crate::painter::Brush::Solid(_)));
}

#[test]
fn arrowed_line_is_not_convertible() {
    let mut s = stroke(Color::BLACK, 2.0);
    s.end_arrow = Arrowhead::SimpleArrow;
    let e = LineElem {
        x1: 0.0, y1: 0.0, x2: 10.0, y2: 0.0,
        stroke: Some(s), width_points: vec![], common: common(), stroke_gradient: None,
    };
    assert!(line_painter_inputs(&e).is_none(), "an arrowhead forces legacy");
}

#[test]
fn gradient_or_aligned_line_is_not_convertible() {
    // Inside alignment → legacy.
    let e1 = LineElem {
        x1: 0.0, y1: 0.0, x2: 10.0, y2: 0.0,
        stroke: Some(stroke_aligned(Color::BLACK, 2.0, StrokeAlign::Inside)),
        width_points: vec![], common: common(), stroke_gradient: None,
    };
    assert!(line_painter_inputs(&e1).is_none(), "inside align forces legacy");
    // Stroke gradient → legacy.
    let e2 = LineElem {
        x1: 0.0, y1: 0.0, x2: 10.0, y2: 0.0,
        stroke: Some(stroke(Color::BLACK, 2.0)),
        width_points: vec![], common: common(), stroke_gradient: Some(linear_grad(0.0)),
    };
    assert!(line_painter_inputs(&e2).is_none(), "stroke gradient forces legacy");
}

/// The convertible-line Painter op is byte-stable: recording the same line's
/// `stroke_path` yields the committed golden `ref_line_convert.json`. This is
/// the PH3 gate — it locks the exact Painter op the production `render.rs` Line
/// arm emits (with `paint_alpha = base_alpha * stroke_op`; here base_alpha 1.0).
#[test]
fn convertible_line_op_matches_golden() {
    let json = render_line_convert();
    let golden = std::fs::read_to_string(golden_path("ref_line_convert"))
        .unwrap_or_else(|_| panic!("missing ref_line_convert golden; run regenerate_reference_goldens"));
    assert_eq!(json.trim(), golden.trim(), "converted line op diverged from golden");
}

// ---------------------------------------------------------------------------
// PH2 — the multi-paint production conversion (per-kind convert goldens +
// capability-exclusion negatives). Each convert golden records exactly the
// Painter ops the production `render.rs` arm emits for a fixed convertible
// element, locking the display-list-equivalent op sequence (contract R4).
// ---------------------------------------------------------------------------

fn freeform_grad() -> Box<Gradient> {
    Box::new(Gradient { gtype: GradientType::Freeform, ..Gradient::default() })
}

fn anchor_dash(width: f64) -> Stroke {
    let mut s = stroke(Color::BLACK, width);
    s.dash_pattern[0] = 6.0;
    s.dash_pattern[1] = 3.0;
    s.dash_len = 2;
    s.dash_align_anchors = true;
    s
}

/// Record the Painter ops for a convertible element (as the production call
/// site does), canonically. Shared by the gate test and the regenerator.
fn record_convert(sp: &ShapePaint, base_alpha: f64) -> String {
    let mut rec = RecordingPainter::new();
    emit_shape_paint(&mut rec, sp, base_alpha);
    let mut json = rec.to_canonical_json();
    json.push('\n');
    json
}

/// The convertible reference elements: `(golden name, resolved paint, base_alpha)`.
fn convert_cases() -> Vec<(&'static str, ShapePaint, f64)> {
    vec![
        ("ref_rect_convert", rect_case(), 0.9),
        ("ref_rect_gradstroke_convert", rect_gradstroke_case(), 1.0),
        ("ref_circle_convert", circle_case(), 0.8),
        ("ref_ellipse_convert", ellipse_case(), 1.0),
        ("ref_polyline_convert", polyline_case(), 0.75),
        ("ref_polygon_convert", polygon_case(), 0.6),
        ("ref_path_convert", path_case(), 0.85),
    ]
}

fn path_case() -> ShapePaint {
    // A two-subpath EvenOdd path (boolean-op output) with a fill and a solid
    // center stroke — locks the A3 winding riding fill_path.
    let e = PathElem {
        d: vec![
            PathCommand::MoveTo { x: 20.0, y: 200.0 },
            PathCommand::CurveTo { x1: 60.0, y1: 120.0, x2: 140.0, y2: 280.0, x: 180.0, y: 200.0 },
            PathCommand::ClosePath,
            PathCommand::MoveTo { x: 60.0, y: 200.0 },
            PathCommand::LineTo { x: 140.0, y: 200.0 },
            PathCommand::LineTo { x: 100.0, y: 170.0 },
            PathCommand::ClosePath,
        ],
        fill: fill(Color::rgb(0.2, 0.6, 0.3)),
        stroke: Some(stroke(Color::BLACK, 2.0)),
        fill_rule: FillRule::EvenOdd,
        common: common(),
        ..PathElem::default()
    };
    path_painter_inputs(&e, elem_bounds_path(&e)).expect("convertible path")
}

/// The bbox the legacy Path arm resolves gradients on (`elem.bounds()`).
fn elem_bounds_path(e: &PathElem) -> (f64, f64, f64, f64) {
    Element::Path(e.clone()).bounds()
}

fn rect_gradstroke_case() -> ShapePaint {
    // A wide gradient STROKE must resolve its gradient on the geometry bbox
    // the legacy Rect arm passes; a stroke-inflated bbox (±10 here) would
    // shift the recorded gradient endpoints and diverge from this golden.
    let e = RectElem {
        x: 15.0, y: 25.0, width: 120.0, height: 70.0, rx: 0.0, ry: 0.0,
        fill: fill(Color::rgb(0.9, 0.9, 0.2)),
        stroke: Some(stroke(Color::BLACK, 20.0)),
        common: common(),
        fill_gradient: None,
        stroke_gradient: Some(linear_grad(0.0)),
    };
    rect_painter_inputs(&e, (e.x, e.y, e.width, e.height))
        .expect("convertible gradient-stroke rect")
}

fn polygon_case() -> ShapePaint {
    let e = PolygonElem {
        points: vec![(40.0, 180.0), (100.0, 180.0), (80.0, 240.0), (50.0, 230.0)],
        fill: fill_op(Color::rgb(0.2, 0.6, 0.3), 0.9),
        stroke: Some(stroke(Color::BLACK, 2.0)),
        common: common(), fill_gradient: None, stroke_gradient: None,
    };
    polygon_painter_inputs(&e, super::poly_bbox(&e.points)).expect("convertible polygon")
}

fn polyline_case() -> ShapePaint {
    let e = PolylineElem {
        points: vec![(20.0, 200.0), (60.0, 150.0), (110.0, 210.0), (160.0, 160.0)],
        fill: None,
        stroke: Some(stroke(Color::rgb(0.8, 0.4, 0.0), 2.5)),
        common: common(), fill_gradient: None, stroke_gradient: None,
    };
    polyline_painter_inputs(&e, super::poly_bbox(&e.points)).expect("convertible polyline")
}

fn ellipse_bbox(e: &EllipseElem) -> (f64, f64, f64, f64) {
    (e.cx - e.rx, e.cy - e.ry, e.rx * 2.0, e.ry * 2.0)
}

fn ellipse_case() -> ShapePaint {
    let e = EllipseElem {
        cx: 120.0, cy: 80.0, rx: 60.0, ry: 35.0,
        fill: fill(Color::rgb(0.2, 0.4, 0.8)),
        stroke: Some(stroke(Color::rgb(0.1, 0.1, 0.1), 1.5)),
        common: common(), fill_gradient: None, stroke_gradient: None,
    };
    ellipse_painter_inputs(&e, ellipse_bbox(&e)).expect("convertible ellipse")
}

// A round ellipse. Kept as its own helper so the circle-shaped assertions below
// stay legible after the circle KIND went away -- they are still about round
// geometry, which did not.
fn circle_bbox(e: &EllipseElem) -> (f64, f64, f64, f64) {
    (e.cx - e.rx, e.cy - e.ry, e.rx * 2.0, e.ry * 2.0)
}

fn circle_case() -> ShapePaint {
    let e = EllipseElem {
        cx: 90.0, cy: 70.0, rx: 45.0, ry: 45.0,
        fill: fill_op(Color::rgb(0.9, 0.3, 0.2), 0.7),
        stroke: Some(stroke(Color::BLACK, 2.5)),
        common: common(), fill_gradient: None, stroke_gradient: None,
    };
    ellipse_painter_inputs(&e, circle_bbox(&e)).expect("convertible circle")
}

fn rect_case() -> ShapePaint {
    let e = RectElem {
        x: 15.0, y: 25.0, width: 120.0, height: 70.0, rx: 10.0, ry: 6.0,
        fill: fill_op(Color::rgb(0.2, 0.5, 0.8), 0.85),
        stroke: Some(stroke(Color::rgb(0.1, 0.1, 0.1), 3.0)),
        common: common(), fill_gradient: None, stroke_gradient: None,
    };
    rect_painter_inputs(&e, (e.x, e.y, e.width, e.height)).expect("convertible rect")
}

/// Every convert case serializes to exactly its committed golden.
#[test]
fn convert_ops_match_goldens() {
    for (name, sp, alpha) in convert_cases() {
        let json = record_convert(&sp, alpha);
        let golden = std::fs::read_to_string(golden_path(name))
            .unwrap_or_else(|_| panic!("missing golden {name}; run regenerate_reference_goldens"));
        assert_eq!(json.trim(), golden.trim(), "convert case {name} diverged from its golden");
    }
}

// -- Rect --------------------------------------------------------------------

fn plain_rect_elem() -> RectElem {
    RectElem {
        x: 15.0, y: 25.0, width: 120.0, height: 70.0, rx: 0.0, ry: 0.0,
        fill: fill(Color::rgb(0.2, 0.5, 0.8)),
        stroke: Some(stroke(Color::BLACK, 2.0)),
        common: common(), fill_gradient: None, stroke_gradient: None,
    }
}

#[test]
fn rect_plain_solid_is_convertible() {
    let e = plain_rect_elem();
    let sp = rect_painter_inputs(&e, (e.x, e.y, e.width, e.height)).expect("plain rect converts");
    assert!(sp.fill.is_some(), "has a fill");
    assert!(sp.stroke.is_some(), "has a stroke");
    assert!(matches!(sp.geom, ConvGeom::Path(_)), "rect lowers to a path");
}

#[test]
fn rect_freeform_gradient_not_convertible() {
    let mut e = plain_rect_elem();
    e.fill_gradient = Some(freeform_grad());
    assert!(
        rect_painter_inputs(&e, (e.x, e.y, e.width, e.height)).is_none(),
        "freeform fill gradient stays legacy"
    );
    let mut e = plain_rect_elem();
    e.stroke_gradient = Some(freeform_grad());
    assert!(
        rect_painter_inputs(&e, (e.x, e.y, e.width, e.height)).is_none(),
        "freeform stroke gradient stays legacy"
    );
}

#[test]
fn rect_anchor_dash_not_convertible() {
    let mut e = plain_rect_elem();
    e.stroke = Some(anchor_dash(3.0));
    assert!(
        rect_painter_inputs(&e, (e.x, e.y, e.width, e.height)).is_none(),
        "anchor-aligned dashing expands to sub-paths — stays legacy"
    );
}

#[test]
fn rect_regular_dash_is_convertible() {
    // A plain (non-anchor) dash carries in the stroke style — convertible.
    let mut s = stroke(Color::BLACK, 2.0);
    s.dash_pattern[0] = 6.0;
    s.dash_pattern[1] = 3.0;
    s.dash_len = 2;
    let mut e = plain_rect_elem();
    e.stroke = Some(s);
    let sp = rect_painter_inputs(&e, (e.x, e.y, e.width, e.height)).expect("regular dash converts");
    let cs = sp.stroke.expect("stroke");
    assert_eq!(cs.style.dash, vec![6.0, 3.0], "the dash pattern crosses the seam");
}

// -- Circle ------------------------------------------------------------------

fn plain_circle_elem() -> EllipseElem {
    EllipseElem {
        cx: 90.0, cy: 70.0, rx: 45.0, ry: 45.0,
        fill: fill(Color::rgb(0.9, 0.3, 0.2)),
        stroke: Some(stroke(Color::BLACK, 2.0)),
        common: common(), fill_gradient: None, stroke_gradient: None,
    }
}

#[test]
fn circle_center_solid_is_convertible() {
    let e = plain_circle_elem();
    let sp = ellipse_painter_inputs(&e, circle_bbox(&e)).expect("center circle converts");
    assert!(matches!(sp.geom, ConvGeom::Arc(_)), "circle lowers to an ellipse arc");
    assert!(sp.fill.is_some() && sp.stroke.is_some());
}

#[test]
fn circle_non_center_stroke_not_convertible() {
    for align in [StrokeAlign::Inside, StrokeAlign::Outside] {
        let mut e = plain_circle_elem();
        e.stroke = Some(stroke_aligned(Color::BLACK, 4.0, align));
        assert!(
            ellipse_painter_inputs(&e, circle_bbox(&e)).is_none(),
            "RP3: a {align:?}-aligned circle stroke stays legacy"
        );
    }
}

#[test]
fn circle_freeform_gradient_not_convertible() {
    let mut e = plain_circle_elem();
    e.fill_gradient = Some(freeform_grad());
    assert!(ellipse_painter_inputs(&e, circle_bbox(&e)).is_none());
}

#[test]
fn circle_anchor_dash_renders_solid_and_converts() {
    // A circle has no dasher-expansion arm: anchor dashing renders SOLID in
    // legacy (the platform dash is cleared), and the seam clears it too — so
    // the circle stays convertible with an empty dash (equivalent, not excluded).
    let mut e = plain_circle_elem();
    e.stroke = Some(anchor_dash(3.0));
    let sp = ellipse_painter_inputs(&e, circle_bbox(&e)).expect("anchor-dash circle still converts");
    assert!(sp.stroke.expect("stroke").style.dash.is_empty(), "anchor dash lowers to solid");
}

// -- Ellipse -----------------------------------------------------------------

fn plain_ellipse_elem() -> EllipseElem {
    EllipseElem {
        cx: 120.0, cy: 80.0, rx: 60.0, ry: 35.0,
        fill: fill(Color::rgb(0.2, 0.4, 0.8)),
        stroke: Some(stroke(Color::BLACK, 2.0)),
        common: common(), fill_gradient: None, stroke_gradient: None,
    }
}

#[test]
fn ellipse_center_solid_is_convertible() {
    let e = plain_ellipse_elem();
    let sp = ellipse_painter_inputs(&e, ellipse_bbox(&e)).expect("center ellipse converts");
    assert!(matches!(sp.geom, ConvGeom::Arc(_)), "ellipse lowers to an ellipse arc");
}

#[test]
fn ellipse_non_center_stroke_not_convertible() {
    for align in [StrokeAlign::Inside, StrokeAlign::Outside] {
        let mut e = plain_ellipse_elem();
        e.stroke = Some(stroke_aligned(Color::BLACK, 4.0, align));
        assert!(
            ellipse_painter_inputs(&e, ellipse_bbox(&e)).is_none(),
            "RP3: a {align:?}-aligned ellipse stroke stays legacy"
        );
    }
}

#[test]
fn ellipse_freeform_gradient_not_convertible() {
    let mut e = plain_ellipse_elem();
    e.stroke_gradient = Some(freeform_grad());
    assert!(ellipse_painter_inputs(&e, ellipse_bbox(&e)).is_none());
}

// -- Polyline ----------------------------------------------------------------

fn plain_polyline_elem() -> PolylineElem {
    PolylineElem {
        points: vec![(20.0, 200.0), (60.0, 150.0), (110.0, 210.0)],
        fill: None,
        stroke: Some(stroke(Color::BLACK, 2.0)),
        common: common(), fill_gradient: None, stroke_gradient: None,
    }
}

#[test]
fn polyline_open_path_is_convertible() {
    let e = plain_polyline_elem();
    let sp = polyline_painter_inputs(&e, super::poly_bbox(&e.points)).expect("polyline converts");
    if let ConvGeom::Path(p) = &sp.geom {
        // Open: no ClosePath command.
        assert!(!p.iter().any(|c| matches!(c, crate::geometry::element::PathCommand::ClosePath)));
    } else {
        panic!("polyline lowers to a path");
    }
}

#[test]
fn polyline_empty_points_not_convertible() {
    let e = PolylineElem { points: vec![], ..plain_polyline_elem() };
    assert!(polyline_painter_inputs(&e, super::poly_bbox(&e.points)).is_none());
}

#[test]
fn polyline_freeform_gradient_not_convertible() {
    let mut e = plain_polyline_elem();
    e.fill_gradient = Some(freeform_grad());
    assert!(polyline_painter_inputs(&e, super::poly_bbox(&e.points)).is_none());
}

/// An inside-aligned path stroke lowers to the build-time clip sequence
/// (save · clip · stroke at 2× width · restore) — the shared A5 lowering.
#[test]
fn inside_align_stroke_uses_clip_lowering() {
    let mut e = plain_polyline_elem();
    e.stroke = Some(stroke_aligned(Color::BLACK, 3.0, StrokeAlign::Inside));
    let sp = polyline_painter_inputs(&e, super::poly_bbox(&e.points)).expect("converts");
    let mut rec = RecordingPainter::new();
    emit_shape_paint(&mut rec, &sp, 1.0);
    let cmds = rec.commands();
    assert!(
        matches!(cmds[0], Command::PushState { .. })
            && matches!(cmds[1], Command::Clip { .. })
            && matches!(cmds[3], Command::PopState),
        "inside align emits push_state · clip · stroke_path · pop_state, got {cmds:?}"
    );
    match &cmds[2] {
        Command::StrokePath { stroke, .. } => {
            assert_eq!(stroke.width, 6.0, "inside stroke is drawn at 2× width")
        }
        other => panic!("expected a stroke_path at index 2, got {other:?}"),
    }
}

// -- Polygon -----------------------------------------------------------------

fn plain_polygon_elem() -> PolygonElem {
    PolygonElem {
        points: vec![(40.0, 180.0), (100.0, 180.0), (80.0, 240.0), (50.0, 230.0)],
        fill: fill(Color::rgb(0.2, 0.6, 0.3)),
        stroke: Some(stroke(Color::BLACK, 2.0)),
        common: common(), fill_gradient: None, stroke_gradient: None,
    }
}

#[test]
fn polygon_closed_path_is_convertible() {
    let e = plain_polygon_elem();
    let sp = polygon_painter_inputs(&e, super::poly_bbox(&e.points)).expect("polygon converts");
    if let ConvGeom::Path(p) = &sp.geom {
        // Closed: a ClosePath command terminates the ring.
        assert!(matches!(p.last(), Some(crate::geometry::element::PathCommand::ClosePath)));
    } else {
        panic!("polygon lowers to a path");
    }
    assert!(sp.fill.is_some() && sp.stroke.is_some());
}

#[test]
fn polygon_empty_points_not_convertible() {
    let e = PolygonElem { points: vec![], ..plain_polygon_elem() };
    assert!(polygon_painter_inputs(&e, super::poly_bbox(&e.points)).is_none());
}

#[test]
fn polygon_freeform_gradient_not_convertible() {
    let mut e = plain_polygon_elem();
    e.stroke_gradient = Some(freeform_grad());
    assert!(polygon_painter_inputs(&e, super::poly_bbox(&e.points)).is_none());
}

// -- Path --------------------------------------------------------------------

fn plain_path_elem() -> PathElem {
    PathElem {
        d: vec![
            PathCommand::MoveTo { x: 20.0, y: 200.0 },
            PathCommand::CurveTo { x1: 60.0, y1: 120.0, x2: 140.0, y2: 280.0, x: 180.0, y: 200.0 },
            PathCommand::ClosePath,
        ],
        fill: fill(Color::rgb(0.2, 0.6, 0.3)),
        stroke: Some(stroke(Color::BLACK, 2.0)),
        common: common(),
        ..PathElem::default()
    }
}

#[test]
fn path_solid_center_is_convertible() {
    let e = plain_path_elem();
    let sp = path_painter_inputs(&e, elem_bounds_path(&e)).expect("plain path converts");
    assert!(sp.fill.is_some() && sp.stroke.is_some());
    assert!(matches!(sp.geom, ConvGeom::Path(_)));
}

#[test]
fn path_evenodd_winding_crosses_the_seam() {
    let mut e = plain_path_elem();
    e.fill_rule = FillRule::EvenOdd;
    let sp = path_painter_inputs(&e, elem_bounds_path(&e)).expect("converts");
    assert_eq!(sp.fill.expect("fill").winding, FillRule::EvenOdd, "A3 winding rides fill_path");
}

/// The gradient twin of `path_evenodd_winding_crosses_the_seam`: the
/// winding rule rides `fill_path` whatever the BRUSH is. `conv_fill`
/// takes the rule alongside the brush, so a gradient-painted even-odd
/// path keeps its holes.
///
/// This is the parity mirror of JasSwift
/// Tests/Canvas/GradientFillRuleTests.swift, where the same invariant
/// had to be repaired: Swift's gradient branches clipped and filled with
/// the winding rule unconditionally, so a gradient flooded the holes of
/// an imported even-odd path while Rust kept them.
#[test]
fn path_evenodd_winding_survives_a_gradient_fill() {
    let mut e = plain_path_elem();
    e.fill_rule = FillRule::EvenOdd;
    e.fill_gradient = Some(linear_grad(45.0));
    let sp = path_painter_inputs(&e, elem_bounds_path(&e)).expect("converts");
    let f = sp.fill.expect("fill");
    assert_eq!(f.winding, FillRule::EvenOdd,
               "a gradient brush must not reset the winding rule");
    // And it really is the gradient, not a solid colour fallback.
    assert!(matches!(f.brush, crate::painter::Brush::Linear(_)),
            "expected a linear-gradient brush, got {:?}", f.brush);
    // A gradient STROKE alongside must not disturb it either.
    e.stroke_gradient = Some(linear_grad(90.0));
    let sp = path_painter_inputs(&e, elem_bounds_path(&e)).expect("converts");
    assert_eq!(sp.fill.expect("fill").winding, FillRule::EvenOdd);
}

#[test]
fn path_stroke_brush_not_convertible() {
    // RP2: a set stroke brush renders a filled outline, not a native stroke.
    let mut e = plain_path_elem();
    e.stroke_brush = Some("calligraphic/flat".to_string());
    assert!(path_painter_inputs(&e, elem_bounds_path(&e)).is_none(), "RP2: stroke brush stays legacy");
}

#[test]
fn path_variable_width_not_convertible() {
    let mut e = plain_path_elem();
    e.width_points = vec![
        StrokeWidthPoint { t: 0.0, width_left: 1.0, width_right: 1.0 },
        StrokeWidthPoint { t: 1.0, width_left: 3.0, width_right: 3.0 },
    ];
    assert!(path_painter_inputs(&e, elem_bounds_path(&e)).is_none(), "variable width stays legacy");
}

#[test]
fn path_arrowhead_not_convertible() {
    let mut s = stroke(Color::BLACK, 2.0);
    s.end_arrow = Arrowhead::SimpleArrow;
    let mut e = plain_path_elem();
    e.stroke = Some(s);
    assert!(path_painter_inputs(&e, elem_bounds_path(&e)).is_none(), "arrowheads stay legacy");
}

#[test]
fn path_anchor_dash_not_convertible() {
    let mut e = plain_path_elem();
    e.stroke = Some(anchor_dash(2.0));
    assert!(
        path_painter_inputs(&e, elem_bounds_path(&e)).is_none(),
        "the Path arm expands anchor dashing — stays legacy"
    );
}

#[test]
fn path_freeform_gradient_not_convertible() {
    let mut e = plain_path_elem();
    e.fill_gradient = Some(freeform_grad());
    assert!(path_painter_inputs(&e, elem_bounds_path(&e)).is_none());
}
