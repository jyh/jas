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
    element_needs_legacy, ellipse_painter_inputs, emit_element, subtree_needs_legacy,
    emit_shape_paint, line_painter_inputs, path_painter_inputs, polygon_painter_inputs,
    polyline_painter_inputs, rect_painter_inputs, ConvGeom, ShapePaint,
};
use crate::painter::capability::{Capability, Caps};
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
    // ⭐ ROW CV -- THE PAINT CONTEXT IS PINNED, NOT INHERITED. Live geometry
    // tessellates at the INSTALLED precision, so a golden rendered against
    // whatever the ambient thread-local happened to hold would be a golden of
    // the test runner's state. An empty index is deliberate: these reference
    // documents are self-contained (`ref_live`'s compound shape owns its
    // operands), and a golden that needed a resolver would be pinning the
    // fixture's index as much as the lowering. The by-id paths -- Fork F3 and
    // the dangling-target rule -- are pinned by the assertions below instead.
    //
    // 📌 INERT FOR THE FIVE PRE-CV GOLDENS: none contains a live element, and
    // nothing else reads the context. Their committed bytes are unchanged by
    // this install, which is what `reference_docs_match_goldens` says on the
    // very first run after it.
    let _paint_context = crate::document::id_index::install_paint_context(
        crate::document::id_index::IdIndex::new(),
        crate::geometry::live::DEFAULT_PRECISION,
    );
    let mut rec = RecordingPainter::new();
    // The driver owns the view transform and pushes it as ONE matrix (D2).
    rec.push_state(Transform { a: 1.5, b: 0.0, c: 0.0, d: 1.5, e: 20.0, f: 10.0 });
    for e in elems {
        // The capability router keeps legacy-only elements off the seam. The
        // recorder answers YES to every capability (it materialises every call),
        // which is what keeps these goldens stable across the router flip.
        if !element_needs_legacy(e, Caps::of(&rec)) {
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
        ("ref_live", ref_live()),
    ]
}

/// ROW CV's display-list lock: live geometry as the walk actually emits it.
///
/// Three elements, each pinning something the assertions state separately —
/// a filled+stroked UNION (one ring neither operand has), a SUBTRACT whose
/// result is TWO rings emitted into ONE path (the legacy trace opens one path
/// and closes each ring into it), and a live element under an OUTLINED group
/// (hairline, no fill). Self-contained: every operand is owned, so nothing here
/// depends on an installed index.
///
/// ⛔ THE SUBTRACT DOES RENDER A HOLE, AND UNTIL ROW EH IT DID NOT. This
/// comment read "THE SUBTRACT DOES NOT RENDER A HOLE" on 09/02, which was a
/// true report of the tree and a false report of the contract: the rings are
/// co-oriented, so the non-zero rule the walks were using filled the cutter's
/// interior. The rule is the algorithm layer's to declare (BOOLEAN.md clause
/// 4) and it declares EVEN-ODD. See
/// `the_subtract_rings_are_co_oriented_and_are_read_under_the_declared_even_odd_rule`
/// below: both halves are MEASURED off these committed bytes -- the shared
/// orientation and the declared rule -- not assumed from the operation's name.
fn ref_live() -> Vec<Element> {
    let union = live_union(
        overlapping_operands(),
        fill(Color::rgb(0.9, 0.2, 0.1)),
        Some(stroke(Color::rgb(0.0, 0.0, 0.4), 2.5)),
    );
    let hole = Element::Live(LiveVariant::CompoundShape(CompoundShape {
        operation: CompoundOperation::SubtractFront,
        operands: vec![
            Rc::new(rect(200.0, 0.0, 120.0, 120.0, None, None)),
            Rc::new(rect(230.0, 30.0, 60.0, 60.0, None, None)),
        ],
        fill: fill(Color::rgb(0.1, 0.5, 0.9)),
        stroke: None,
        common: common_alpha(0.6),
    }));
    let mut outlined = GroupElem {
        children: vec![Rc::new(live_union(
            vec![
                rect(0.0, 200.0, 80.0, 80.0, None, None),
                rect(40.0, 240.0, 80.0, 80.0, None, None),
            ],
            fill(Color::WHITE),
            None,
        ))],
        common: common(),
        isolated_blending: false,
        knockout_group: false,
    };
    outlined.common.visibility = Visibility::Outline;
    vec![union, hole, Element::Group(outlined)]
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
    assert!(!element_needs_legacy(&r, Caps::NONE), "plain rect converts on any backend");
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
    assert!(
        element_needs_legacy(&r, Caps::NONE),
        "a masked element stays legacy on a backend that can do neither half -- \
         Direct2D's answer today"
    );
    assert!(
        !element_needs_legacy(&r, Caps::NONE
            .with(Capability::IsolatedLayers)
            .with(Capability::MaskLayers)),
        "a masked element CONVERTS on a backend that executes both halves -- \
         Canvas2D's answer since #55"
    );
}

/// ⭐ THE ARM #56 BOUGHT, AND IT COULD NOT HAVE BEEN WRITTEN BEFORE IT.
///
/// LAYERS BUT NO MASKS is a real backend state, not a hypothetical: it is
/// exactly what `Canvas2dPainter` held from #47 until #55, and it is the state
/// `Direct2DPainter` will pass through if it implements layers before masks —
/// the natural order, since the layer target is the surface a mask eats into.
///
/// Such a backend must stay LEGACY for a masked element: the element bracket
/// needs both halves, and A6 §3.2 makes a mask bracket legal only inside an
/// isolated layer. Until `a6_layer_no_mask.json` landed, no fixture separated
/// the two capabilities, so this state was not expressible in any query derived
/// from the corpus — the query would have said "the A6 bracket" as one unit and
/// this test would have been a lie dressed as a pin.
#[test]
fn a_backend_with_layers_but_no_masks_keeps_a_masked_element_on_legacy() {
    use crate::geometry::element::Mask;
    let mut r = rect(0.0, 0.0, 10.0, 10.0, fill(Color::BLACK), None);
    if let Element::Rect(e) = &mut r {
        e.common.mask = Some(Box::new(Mask {
            subtree: Box::new(rect(0.0, 0.0, 10.0, 10.0, fill(Color::WHITE), None)),
            clip: false, invert: false, disabled: false, linked: true, unlink_transform: None,
        }));
    }
    let layers_only = Caps::NONE.with(Capability::IsolatedLayers);
    assert!(
        element_needs_legacy(&r, layers_only),
        "half the bracket is not the bracket -- routing here would open a layer \
         and then panic in push_mask_layer"
    );
    // ...and the converse, so this is not just "everything is legacy": the SAME
    // element converts the moment the other half arrives. One variable.
    assert!(!element_needs_legacy(&r, layers_only.with(Capability::MaskLayers)));

    // 📌 THE OTHER HALF OF THE CONJUNCTION, AND ITS STATUS SAID PLAINLY. Masks
    // WITHOUT layers is a legal `Caps` value and the router must handle it, but
    // NO fixture can reach it and no backend can hold it: A6 §3.2 makes a mask
    // bracket legal only inside an isolated layer, which
    // `capability::tests::no_scene_carries_a_mask_outside_an_isolated_layer`
    // asserts over the whole corpus. So this arm is DEFENSIVE, not observed —
    // it is here so the `&&` is driven from both sides rather than half-tested,
    // and it is labelled rather than counted as evidence.
    assert!(
        element_needs_legacy(&r, Caps::NONE.with(Capability::MaskLayers)),
        "masks without layers is not the bracket either"
    );
}

/// A DISABLED mask is not an active one, on ANY backend: the element renders as
/// if none were attached, which is what the legacy `mask_plan` says too.
/// Capability-independent, and asserted at both poles so a future "caps unlock
/// everything" reading cannot take hold.
#[test]
fn a_disabled_mask_is_not_a_capability_question() {
    use crate::geometry::element::Mask;
    let mut r = rect(0.0, 0.0, 10.0, 10.0, fill(Color::BLACK), None);
    if let Element::Rect(e) = &mut r {
        e.common.mask = Some(Box::new(Mask {
            subtree: Box::new(rect(0.0, 0.0, 10.0, 10.0, fill(Color::WHITE), None)),
            clip: false, invert: false, disabled: true, linked: true, unlink_transform: None,
        }));
    }
    assert!(!element_needs_legacy(&r, Caps::NONE));
    assert!(!element_needs_legacy(&r, all_caps()));
}

#[test]
fn freeform_gradient_needs_legacy() {
    let mut e = RectElem {
        x: 0.0, y: 0.0, width: 10.0, height: 10.0, rx: 0.0, ry: 0.0,
        fill: fill(Color::WHITE), stroke: None,
        common: common(), fill_gradient: None, stroke_gradient: None,
    };
    e.fill_gradient = Some(Box::new(Gradient { gtype: GradientType::Freeform, ..Gradient::default() }));
    let e = Element::Rect(e);
    assert!(element_needs_legacy(&e, Caps::NONE), "freeform gradient stays legacy");
    // ⛔ AND IT STAYS LEGACY ON A BACKEND THAT CAN DO EVERYTHING. A freeform
    // gradient is a BUILD-TIME lowering concern that never crosses the seam
    // (contract A5) -- there is no capability for it and there must not be one,
    // or the router would start asking backends about a question they cannot
    // answer. The two clauses of this router are different KINDS of "no".
    assert!(element_needs_legacy(&e, all_caps()), "freeform gradient is not a backend question");
}

#[test]
fn groups_and_shapes_do_not_need_legacy() {
    // Sanity: nested groups and plain shapes route through the seam.
    for (_name, doc) in reference_docs() {
        for e in &doc {
            assert!(!element_needs_legacy(e, Caps::NONE),
                    "reference-doc element should convert on ANY backend");
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

// ═══════════════════════════════════════════════════════════════════════════
// ⚖️ THE ROUTER FLIP (council 08/29, row (e) = option (b)) — and the
// BEHAVIOUR CHANGE it carries, stated here rather than slipped past a reader.
// ═══════════════════════════════════════════════════════════════════════════

/// Every capability answered YES — the shape of a backend that can do the whole
/// A6 bracket. Written from `Capability::ALL`, so a capability added later is
/// included here without anyone remembering to.
fn all_caps() -> Caps {
    Capability::ALL.into_iter().fold(Caps::NONE, Caps::with)
}

/// A backend that executes everything EXCEPT what the A6 bracket needs.
///
/// ⛔ IT IS A DELEGATING WRAPPER, NOT A STUB, AND THAT IS THE POINT. It records
/// through a real `RecordingPainter`, so "nothing was emitted" is a measurement
/// of the emit path rather than of a painter that drops calls. Only `supports`
/// differs — ONE VARIABLE against the same test run through the recorder
/// itself, which is what makes the difference attributable to the answer.
struct MaskBlind(RecordingPainter);

impl crate::painter::Painter for MaskBlind {
    fn supports(&self, _c: Capability) -> bool { false }
    fn fill_path(&mut self, p: &[PathCommand], w: FillRule, b: &crate::painter::Brush, a: f64) {
        self.0.fill_path(p, w, b, a)
    }
    fn stroke_path(&mut self, p: &[PathCommand], b: &crate::painter::Brush,
                   s: &crate::painter::StrokeStyle, a: f64) {
        self.0.stroke_path(p, b, s, a)
    }
    fn fill_rect(&mut self, r: crate::painter::Rect, b: &crate::painter::Brush, a: f64) {
        self.0.fill_rect(r, b, a)
    }
    fn stroke_rect(&mut self, r: crate::painter::Rect, b: &crate::painter::Brush,
                   s: &crate::painter::StrokeStyle, a: f64) {
        self.0.stroke_rect(r, b, s, a)
    }
    fn fill_ellipse_arc(&mut self, e: &crate::painter::EllipseArc, w: FillRule,
                        b: &crate::painter::Brush, a: f64) {
        self.0.fill_ellipse_arc(e, w, b, a)
    }
    fn stroke_ellipse_arc(&mut self, e: &crate::painter::EllipseArc, b: &crate::painter::Brush,
                          s: &crate::painter::StrokeStyle,
                          al: crate::painter::StrokeAlign, a: f64) {
        self.0.stroke_ellipse_arc(e, b, s, al, a)
    }
    fn clip(&mut self, p: &[PathCommand], w: FillRule) { self.0.clip(p, w) }
    fn push_state(&mut self, t: Transform) { self.0.push_state(t) }
    fn pop_state(&mut self) { self.0.pop_state() }
    fn push_group(&mut self, a: f64, b: crate::painter::BlendMode) { self.0.push_group(a, b) }
    fn pop_group(&mut self) { self.0.pop_group() }
    fn push_mask_layer(&mut self, m: crate::painter::Mask) { self.0.push_mask_layer(m) }
    fn pop_mask_layer(&mut self) { self.0.pop_mask_layer() }
    fn push_isolated_layer(&mut self, a: f64, b: crate::painter::BlendMode) {
        self.0.push_isolated_layer(a, b)
    }
    fn pop_isolated_layer(&mut self) { self.0.pop_isolated_layer() }
    fn draw_text_run(&mut self, r: &crate::painter::TextRun, b: &crate::painter::Brush, a: f64) {
        self.0.draw_text_run(r, b, a)
    }
}

/// A 0.5-alpha group holding a 0.5-opacity MASKED rect — A6 §6.2's shape, the
/// one where HEAD and the contract disagree.
fn group_with_a_masked_child() -> Element {
    use crate::geometry::element::Mask;
    let mut child = rect(0.0, 0.0, 10.0, 10.0, fill(Color::BLACK), None);
    if let Element::Rect(e) = &mut child {
        e.common.opacity = 0.5;
        e.common.mask = Some(Box::new(Mask {
            subtree: Box::new(rect(0.0, 0.0, 10.0, 10.0, fill(Color::WHITE), None)),
            clip: true, invert: false, disabled: false, linked: true, unlink_transform: None,
        }));
    }
    Element::Group(GroupElem {
        children: vec![Rc::new(child)],
        common: common_alpha(0.5),
        isolated_blending: false,
        knockout_group: false,
    })
}

/// ⛔ THE FLIP ITSELF, AND IT IS A RATIFIED BEHAVIOUR CHANGE — A6 §6.2.
///
/// Before this commit the router asked only about the ELEMENT, so a masked
/// child of a group was skipped by every backend, forever, including the one
/// that has executed both halves since #55. It now asks the BACKEND, and a
/// mask-capable backend emits the element bracket.
///
/// ⚠️ WHAT THIS TEST OBSERVES is the SHAPE of the emission and the alpha each
/// op carries — the layer takes the element's own opacity, the body paints at
/// the ancestor product. That is the contract, and it is what belongs here.
///
/// ⛔ WHAT IT DOES NOT OBSERVE, corrected 2026-08-30. This comment used to end
/// "HEAD's legacy path gives `own²` with the ancestors DISCARDED … so a
/// 0.5-opacity element in a 0.5-alpha group came out at 0.25". That was D-α,
/// and it had been repaired in `canvas/render.rs` five days before this test
/// was written (`mask_blit_alpha`, `c59e5349`). Worse, the example it named
/// gives 0.25 under the defect AND under the law — the commit that fixed D-α
/// says so in as many words — so the witness could not have separated them.
/// ⇒ **A DISPLAY-LIST TEST CANNOT SEE THE LEGACY PATH AT ALL**, and a claim
/// about what the other path does had no business being asserted from here.
/// The real difference is which factor is ISOLATED, it needs a body that
/// overlaps itself to show up, and it is measured where it can be:
/// `canvas::render::ph4_conversion_tests`, in a browser, both paths, both
/// directions.
#[test]
fn a_mask_capable_backend_now_emits_the_bracket_for_a_masked_group_child() {
    let g = group_with_a_masked_child();
    let mut rec = RecordingPainter::new();
    emit_element(&mut rec, &g, 1.0);
    let json = rec.to_canonical_json();
    assert!(json.contains("push_isolated_layer"),
            "the mask-capable backend must now receive the A6 bracket:\n{json}");
    assert!(json.contains("push_mask_layer"), "…including the mask half:\n{json}");

    // ⛔ AND THE ALPHA LAW IS VISIBLE IN IT, because "the bracket was emitted"
    // is not the same claim as "each factor applied once". The layer carries the
    // element's own 0.5; the body paints at the ANCESTOR product (0.5), not at
    // 0.25. HEAD's `own²` would have put 0.25 on the body and nothing on the
    // ancestors.
    let ops: serde_json::Value = serde_json::from_str(&json).expect("canonical JSON");
    let ops = ops.as_array().expect("an array of commands");
    let alpha_of = |cmd: &str| -> f64 {
        ops.iter()
            .find(|o| o["cmd"] == cmd)
            .unwrap_or_else(|| panic!("no {cmd} in:\n{json}"))["alpha"]
            .as_f64()
            .unwrap_or_else(|| panic!("{cmd} carries no alpha"))
    };
    // The LAYER carries the element's own 0.5, spent once at the composite.
    assert_eq!(alpha_of("push_isolated_layer"), 0.5, "the layer carries own opacity");
    // The BODY paints at the ANCESTOR product (the group's 0.5) — NOT at
    // own × ancestors, and NOT at own². HEAD gives 0.25 here and discards the
    // group entirely; that difference IS the ratified §6.2 behaviour change.
    assert_eq!(alpha_of("fill_rect"), 0.5,
               "the body paints at the ancestor product; 0.25 would be HEAD's \
                own-squared, the law this bracket replaces:\n{json}");
    // The mask artwork is itself isolated: fresh surface, alpha context 1.0.
    let mask_art = ops.iter().skip_while(|o| o["cmd"] != "push_mask_layer")
        .find(|o| o["cmd"] == "fill_rect")
        .expect("mask artwork");
    assert_eq!(mask_art["alpha"].as_f64(), Some(1.0),
               "the mask bracket is isolated at alpha 1.0 (A6 §3.2)");
}

/// ...and the SAME document through a backend that answers NO emits NOTHING for
/// that child — it stays legacy, exactly as Direct2D will.
///
/// ONE VARIABLE. The two arms differ only in the `supports` answer: same
/// element, same emit path, same recorder underneath. Differing outputs prove
/// an arm CAN fire; holding everything else fixed is what makes the difference
/// attributable to the query rather than to the two arms being two programs.
#[test]
fn a_backend_that_answers_no_still_gets_nothing_for_a_masked_child() {
    let g = group_with_a_masked_child();
    let mut blind = MaskBlind(RecordingPainter::new());
    emit_element(&mut blind, &g, 1.0);
    let json = blind.0.to_canonical_json();
    assert!(!json.contains("push_mask_layer"),
            "a backend without masks must not be handed a mask bracket -- \
             push_mask_layer is `unimplemented!()` there:\n{json}");
    assert!(!json.contains("push_isolated_layer"),
            "…nor half of one:\n{json}");
    assert!(!json.contains("fill_rect"),
            "the masked child paints nothing on a legacy-routed backend, as it \
             did before this commit:\n{json}");
}

/// ⛔ AND THE PRECONDITION IS ENFORCED ONE FRAME IN, NOT ONLY AT THE GROUP LOOP.
///
/// The test above enters through a GROUP, so what protects the backend there is
/// the child-loop's router call. A caller reaching `emit_element` DIRECTLY with
/// a masked element used to be told "assumes `!element_needs_legacy`" in a doc
/// comment — a duty dischargeable only while the answer was constant. It is not
/// constant any more, so the check moved into the function. Without this arm the
/// enforcement inside `emit_element` would be uncovered, and an uncovered guard
/// is indistinguishable from an absent one.
#[test]
fn emit_element_refuses_to_hand_the_bracket_to_a_backend_that_answers_no() {
    use crate::geometry::element::Mask;
    let mut child = rect(0.0, 0.0, 10.0, 10.0, fill(Color::BLACK), None);
    if let Element::Rect(e) = &mut child {
        e.common.mask = Some(Box::new(Mask {
            subtree: Box::new(rect(0.0, 0.0, 10.0, 10.0, fill(Color::WHITE), None)),
            clip: true, invert: false, disabled: false, linked: true, unlink_transform: None,
        }));
    }
    let mut blind = MaskBlind(RecordingPainter::new());
    emit_element(&mut blind, &child, 1.0);
    let emitted: serde_json::Value =
        serde_json::from_str(&blind.0.to_canonical_json()).expect("canonical JSON");
    assert_eq!(emitted.as_array().map(Vec::len), Some(0),
               "a direct call must emit NOTHING rather than a bracket the \
                backend cannot execute, got {emitted}");

    // One variable: the same element, the same call, a backend that says yes.
    let mut rec = RecordingPainter::new();
    emit_element(&mut rec, &child, 1.0);
    assert!(rec.to_canonical_json().contains("push_mask_layer"),
            "…and the arm must be able to differ, or it proves nothing");
}

/// ⛔ THE RESPONSIBILITY THAT MOVED MUST STILL BE DISCHARGED, AND BY THE NEW
/// OWNER. The group-children loop used to filter legacy-only children itself;
/// that filter is gone, because `emit_element` now asks the router for every
/// element. This is the arm that proves the filtering did not go with it — a
/// CAPABILITY-INDEPENDENT legacy child (freeform gradient: contract A5, it never
/// crosses the seam on any backend) inside a group must still paint nothing,
/// while its plain sibling paints.
///
/// Without this, moving the check would have been verified only for masks, and
/// the other clauses of the router would have been silently unguarded inside
/// groups — the half of a change that nobody looks at.
#[test]
fn a_legacy_only_child_paints_nothing_even_though_the_loop_no_longer_filters() {
    let mut freeform = RectElem {
        x: 0.0, y: 0.0, width: 10.0, height: 10.0, rx: 0.0, ry: 0.0,
        fill: fill(Color::WHITE), stroke: None,
        common: common(), fill_gradient: None, stroke_gradient: None,
    };
    freeform.fill_gradient =
        Some(Box::new(Gradient { gtype: GradientType::Freeform, ..Gradient::default() }));
    let g = Element::Group(GroupElem {
        children: vec![
            Rc::new(Element::Rect(freeform)),
            Rc::new(rect(50.0, 50.0, 4.0, 4.0, fill(Color::BLACK), None)),
        ],
        common: common(),
        isolated_blending: false,
        knockout_group: false,
    });

    let mut rec = RecordingPainter::new();
    emit_element(&mut rec, &g, 1.0);
    let json = rec.to_canonical_json();
    let ops: serde_json::Value = serde_json::from_str(&json).expect("canonical JSON");
    let fills: Vec<_> = ops.as_array().unwrap().iter()
        .filter(|o| o["cmd"] == "fill_rect").collect();
    assert_eq!(fills.len(), 1,
               "exactly the non-legacy sibling paints -- the freeform-gradient \
                child must be routed away by `emit_element` now that the loop \
                does not:\n{json}");
    assert_eq!(fills[0]["rect"]["x"].as_f64(), Some(50.0),
               "…and it is the SIBLING that survived, not the freeform child");
}

/// ⭐ THE ROUTING END OF CONDITION (i), AND IT DESCRIBES A REAL BACKEND.
///
/// `Caps` with layers + masks but NOT the blend is exactly what Direct2D
/// answers once its A6 ops land: it opens isolated layers and mask brackets,
/// and it has no effect graph for the 15 non-Normal modes. A masked element
/// carrying `multiply` must therefore STAY LEGACY there — because
/// `emit_masked_element` puts the element's own mode on the layer, and a
/// backend that opens the layer without reading its blend would DISCARD the
/// multiply with nothing reporting it.
///
/// ⛔ The point is that the two capabilities do not absorb each other. The SAME
/// element converts the moment the blend answer arrives, and a Normal-mode
/// sibling converts without it — one variable each way, so this cannot pass by
/// refusing everything.
#[test]
fn a_masked_element_with_a_non_normal_blend_needs_the_effect_graph_too() {
    use crate::geometry::element::Mask;
    use crate::painter::BlendMode;

    let masked = |mode: BlendMode| {
        let mut r = rect(0.0, 0.0, 10.0, 10.0, fill(Color::BLACK), None);
        if let Element::Rect(e) = &mut r {
            e.common.mode = mode;
            e.common.mask = Some(Box::new(Mask {
                subtree: Box::new(rect(0.0, 0.0, 10.0, 10.0, fill(Color::WHITE), None)),
                clip: true, invert: false, disabled: false, linked: true, unlink_transform: None,
            }));
        }
        r
    };

    // Direct2D's answer once (a) lands: the bracket, but no effect graph.
    let bracket_no_blend = Caps::NONE
        .with(Capability::IsolatedLayers)
        .with(Capability::MaskLayers);

    assert!(
        element_needs_legacy(&masked(BlendMode::Multiply), bracket_no_blend),
        "a multiply-blended masked element must NOT be routed at a backend with \
         no effect graph -- the layer would open and the multiply would vanish"
    );
    assert!(
        !element_needs_legacy(&masked(BlendMode::Normal), bracket_no_blend),
        "…while a Normal-mode masked element converts there, or the blend \
         requirement has welded itself to the bracket and every mask is legacy"
    );
    assert!(
        !element_needs_legacy(&masked(BlendMode::Multiply), all_caps()),
        "…and the SAME multiply element converts once the blend answer arrives"
    );
}

// ---------------------------------------------------------------------------
// PH4 PRODUCTION ROUTING — the router is SHALLOW, and production is where that
// becomes content loss
// ---------------------------------------------------------------------------

/// A freeform-gradient rect: convertible by nothing, on any backend. The one
/// legacy-only leaf these tests need, built once.
fn freeform_rect() -> Element {
    let mut e = RectElem {
        x: 0.0, y: 0.0, width: 10.0, height: 10.0, rx: 0.0, ry: 0.0,
        fill: fill(Color::WHITE), stroke: None,
        common: common(), fill_gradient: None, stroke_gradient: None,
    };
    e.fill_gradient = Some(Box::new(Gradient {
        gtype: GradientType::Freeform, ..Gradient::default()
    }));
    Element::Rect(e)
}

/// A masked GROUP whose body subtree holds one convertible child and one
/// legacy-only child. The group itself carries nothing legacy — which is the
/// whole point.
fn masked_group_with_a_legacy_child() -> Element {
    use crate::geometry::element::Mask;
    let mut g = GroupElem {
        children: vec![
            Rc::new(rect(0.0, 0.0, 10.0, 10.0, fill(Color::BLACK), None)),
            Rc::new(freeform_rect()),
        ],
        common: common(),
        isolated_blending: false,
        knockout_group: false,
    };
    g.common.mask = Some(Box::new(Mask {
        subtree: Box::new(rect(0.0, 0.0, 10.0, 10.0, fill(Color::WHITE), None)),
        clip: true, invert: false, disabled: false, linked: true, unlink_transform: None,
    }));
    Element::Group(g)
}

/// A masked rect whose MASK ARTWORK is legacy-only. The body is ordinary.
fn masked_rect_with_a_legacy_mask() -> Element {
    use crate::geometry::element::Mask;
    let mut r = rect(0.0, 0.0, 10.0, 10.0, fill(Color::BLACK), None);
    if let Element::Rect(e) = &mut r {
        e.common.mask = Some(Box::new(Mask {
            subtree: Box::new(freeform_rect()),
            clip: true, invert: false, disabled: false, linked: true, unlink_transform: None,
        }));
    }
    r
}

/// ⛔ THE HAZARD, MEASURED RATHER THAN ASSERTED FROM READING.
///
/// [`element_needs_legacy`] answers about ONE NODE. That is correct for the
/// reference renderer, whose corpora are PH1-expressible by construction, and
/// it is the reason the guard below has to exist for production: a document is
/// not a corpus. This test drives the bracket at a document the shallow router
/// says yes to and counts what reaches the painter.
///
/// It asserts the LOSS deliberately. A guard whose hazard is only described in
/// prose is indistinguishable from one guarding nothing; this is the arm that
/// makes [`subtree_needs_legacy`]'s red legible if someone ever deletes it.
#[test]
fn the_shallow_router_says_yes_to_a_masked_group_that_would_lose_a_child() {
    let g = masked_group_with_a_legacy_child();

    // 1. The shallow router — the one the REFERENCE renderer asks — says convert.
    assert!(!element_needs_legacy(&g, all_caps()),
            "the node itself carries nothing legacy; that is why the shallow \
             answer cannot be the production answer");

    // 2. …and the emission drops the legacy child ENTIRELY. The GROUP has two
    //    children; the BODY span (everything before `PushMaskLayer`) carries
    //    exactly one paint. That gap of one IS the loss, and nothing in the op
    //    stream marks it.
    assert_eq!(g.children().map(<[_]>::len), Some(2), "the document has two body children");
    let got = ops(&g, 1.0);
    let body_paints = got
        .iter()
        .take_while(|c| !matches!(c, Command::PushMaskLayer { .. }))
        .filter(|c| matches!(c, Command::FillRect { .. }))
        .count();
    assert_eq!(body_paints, 1,
               "two body children, one paint: the freeform child is gone and \
                the bracket closed over the hole:\n{got:#?}");
}

/// THE GUARD. Production must ask about the WHOLE subtree, both halves.
#[test]
fn production_routing_refuses_a_masked_element_whose_body_subtree_needs_legacy() {
    let g = masked_group_with_a_legacy_child();
    assert!(subtree_needs_legacy(&g, all_caps()),
            "a masked element with a legacy-only DESCENDANT must stay legacy in \
             production, or that descendant is silently dropped");
}

/// ⛔ THE WORSE ARM, AND IT IS A DIFFERENT FAILURE, NOT A BIGGER ONE.
///
/// A dropped body child loses that child. A dropped MASK ARTWORK loses the
/// WHOLE ELEMENT: `LuminanceClipIn` is `α_S ← α_S · M`, and artwork that paints
/// nothing gives `M = 0` everywhere. The element disappears rather than
/// degrades — so the mask subtree needs the same check, and it needs its own
/// arm because a guard that walked only the body would pass every assertion
/// above.
#[test]
fn production_routing_refuses_a_masked_element_whose_mask_subtree_needs_legacy() {
    let r = masked_rect_with_a_legacy_mask();
    assert!(!element_needs_legacy(&r, all_caps()),
            "the shallow router does not look inside the mask either");
    assert!(subtree_needs_legacy(&r, all_caps()),
            "legacy-only MASK ARTWORK must keep the element on legacy; \
             empty artwork means M = 0 and the element vanishes");
}

/// THE POSITIVE CONTROL. A guard that only ever refuses converts nothing and
/// cannot be told from a `return true`.
#[test]
fn production_routing_accepts_a_fully_convertible_masked_element() {
    assert!(!subtree_needs_legacy(&masked_rect(true, false), all_caps()),
            "a masked element whose body AND mask are PH1-expressible must \
             convert, or the production router is a constant");
    // …and the backend answer still governs, deep or not.
    assert!(subtree_needs_legacy(&masked_rect(true, false), Caps::NONE),
            "the capability question survives the deep walk");
}

/// The deep walk must not change the answer for anything WITHOUT a mask — it is
/// the masked path's guard, not a second router.
#[test]
fn the_deep_walk_agrees_with_the_shallow_one_on_the_reference_docs() {
    for (name, doc) in reference_docs() {
        for e in &doc {
            assert_eq!(subtree_needs_legacy(e, all_caps()), element_needs_legacy(e, all_caps()),
                       "{name}: the deep walk must not reclassify an unmasked \
                        reference element");
        }
    }
}

/// ⭐ OUTLINE MODE CONVERTS NOW — and this arm is the RETIREMENT of its opposite.
///
/// It used to read `outline_visibility_needs_legacy_on_every_backend`, with this
/// stated ground: *"there is no such lowering on the seam — so a converted
/// outline element would render its NORMAL paints, which is a wrong picture
/// rather than a missing one."*
///
/// ⛔ THE GROUND IS GONE, NOT MERELY INCONVENIENT. `emit_outline_body` is that
/// lowering (node 2, ported from `render.rs::apply_outline_style`), so the
/// premise the old assertion rested on is false. A clause kept past its reason
/// is one nothing drives, and a test that pins it turns a stale rule into a
/// requirement.
///
/// What replaces it is the same question asked of the NEW behaviour: does a
/// masked subtree with an outlined descendant still render CORRECTLY, rather
/// than merely render?
#[test]
fn an_outline_element_converts_and_an_outlined_descendant_no_longer_forces_legacy() {
    use crate::geometry::element::Visibility;
    let mut r = rect(0.0, 0.0, 10.0, 10.0, fill(Color::BLACK), None);
    r.common_mut().visibility = Visibility::Outline;
    assert!(!element_needs_legacy(&r, all_caps()),
            "the seam has an outline lowering now");
    assert!(!subtree_needs_legacy(&r, all_caps()));

    // The descendant case the old arm was really about: an outline child inside
    // a masked group. It used to force the whole bracket to legacy because the
    // child would have been painted with its NORMAL fill. Now it is outlined.
    let mut child = rect(0.0, 0.0, 10.0, 10.0, fill(Color::BLACK), None);
    child.common_mut().visibility = Visibility::Outline;
    let mut g = GroupElem {
        children: vec![Rc::new(child)],
        common: common(),
        isolated_blending: false,
        knockout_group: false,
    };
    g.common.mask = Some(Box::new(crate::geometry::element::Mask {
        subtree: Box::new(rect(0.0, 0.0, 10.0, 10.0, fill(Color::WHITE), None)),
        clip: true, invert: false, disabled: false, linked: true, unlink_transform: None,
    }));
    let g = Element::Group(g);
    assert!(!subtree_needs_legacy(&g, all_caps()),
            "an outlined descendant is now lowerable, so it must not force legacy");

    // ⛔ AND IT MUST ACTUALLY DRAW AS AN OUTLINE UNDER THE BRACKET, which is the
    // half "it converts" does not prove. `subtree_needs_legacy` returning false
    // only says the walk will not bail; if the child then painted its black
    // FILL we would have traded a missing picture for a wrong one -- exactly the
    // trade the old arm existed to prevent.
    let mut rec = RecordingPainter::new();
    emit_element(&mut rec, &g, 1.0);
    let cmds = rec.commands();
    let body_fills = cmds.iter()
        .take_while(|c| !matches!(c, Command::PushMaskLayer { .. }))
        .filter(|c| matches!(c, Command::FillRect { .. } | Command::FillPath { .. }))
        .count();
    assert_eq!(body_fills, 0,
               "the outlined child must not fill inside the bracket: {cmds:?}");

    // ⭐ AND THE MASK ARTWORK MUST STILL FILL. It is COVERAGE, not picture: an
    // outline applied to it would replace the shape that defines the mask with a
    // hairline tracing its silhouette -- a different mask, not a differently
    // drawn one. This arm is why `emit_masked_element` passes `Preview` for the
    // subtree rather than the element's own visibility.
    let mask_fills = cmds.iter()
        .skip_while(|c| !matches!(c, Command::PushMaskLayer { .. }))
        .filter(|c| matches!(c, Command::FillRect { .. } | Command::FillPath { .. }))
        .count();
    assert!(mask_fills >= 1,
            "the mask subtree must still paint its coverage: {cmds:?}");

    // THE CONTROL: the same shapes at normal visibility convert and DO fill.
    let mut plain = rect(0.0, 0.0, 10.0, 10.0, fill(Color::BLACK), None);
    plain.common_mut().visibility = Visibility::Preview;
    assert!(!element_needs_legacy(&plain, all_caps()));
    let mut rec2 = RecordingPainter::new();
    emit_element(&mut rec2, &plain, 1.0);
    assert_eq!(fills(&rec2.commands()), 1,
               "…or the outline arms above pass because NOTHING ever fills");
}

// ---------------------------------------------------------------------------
// NODE 2 — THE OUTLINE DELTA, ported from `canvas::render` (never the reverse)
// ---------------------------------------------------------------------------
//
// `render.rs`'s `apply_outline_style` is the whole lowering: no fill, a BLACK
// 1px butt/miter stroke with no dash and miter limit 10, at the element's
// inherited alpha. Its `draw_element_scaled` computes
// `effective = min(ancestor_vis, elem.visibility())`, so outline is INHERITED —
// which is exactly the state `emit_element` could not see, and exactly why
// `draw_masked_element_through_the_seam`'s condition 1 refuses to convert
// anything whose `ancestor_vis` is not `Preview`.

use super::emit_element_with_vis;
use crate::geometry::element::Visibility;
use crate::painter::{Brush, StrokeStyle};

/// The stroke `apply_outline_style` installs, as this seam expresses it.
fn outline_style_of(cmds: &[Command]) -> Vec<(&Brush, &StrokeStyle, f64)> {
    cmds.iter()
        .filter_map(|c| match c {
            Command::StrokePath { brush, stroke, paint_alpha, .. }
            | Command::StrokeRect { brush, stroke, paint_alpha, .. } => {
                Some((brush, stroke, *paint_alpha))
            }
            _ => None,
        })
        .collect()
}

fn fills(cmds: &[Command]) -> usize {
    cmds.iter()
        .filter(|c| matches!(c,
            Command::FillPath { .. } | Command::FillRect { .. } | Command::FillEllipseArc { .. }))
        .count()
}

fn outline_rect() -> Element {
    let mut e = rect(10.0, 20.0, 100.0, 60.0,
                     fill(Color::rgb(0.2, 0.4, 0.8)),
                     Some(stroke(Color::rgb(1.0, 0.0, 0.0), 7.0)));
    e.common_mut().visibility = Visibility::Outline;
    e
}

/// ⛔ OUTLINE REPLACES BOTH PAINTS, IT DOES NOT ADD ONE. The element below has a
/// blue fill AND a fat red stroke; outline mode must emit NEITHER, and exactly
/// one black hairline in their place.
#[test]
fn an_outline_element_strokes_a_black_hairline_and_does_not_fill() {
    let mut rec = RecordingPainter::new();
    emit_element(&mut rec, &outline_rect(), 1.0);
    let cmds = rec.commands();

    assert_eq!(fills(&cmds), 0,
               "outline mode replaces the fill with `transparent`; it must not paint one");

    let strokes = outline_style_of(&cmds);
    assert_eq!(strokes.len(), 1, "exactly one stroke, got {}", strokes.len());
    let (brush, style, alpha) = strokes[0];
    assert_eq!(*brush, Brush::Solid(Color::rgb(0.0, 0.0, 0.0)),
               "render.rs sets stroke_style_str('rgb(0,0,0)')");
    assert_eq!(style.width, 1.0, "set_line_width(1.0)");
    assert!(style.dash.is_empty(), "set_line_dash([]) -- the element's dash is DROPPED");
    assert_eq!(alpha, 1.0, "outline carries no stroke opacity of its own");
}

/// ⭐ THE INHERITED HALF, AND IT IS THE REASON THIS NEEDED A NEW ENTRY POINT.
/// `render.rs` takes `min(ancestor_vis, own)`, so a group in outline mode drags
/// every descendant into it — including children whose own visibility is
/// `Preview`. An `emit_element` that only reads the element in its hand cannot
/// express that, which is what production's condition 1 refuses over.
#[test]
fn outline_is_inherited_by_children_that_are_themselves_preview() {
    let child = rect(0.0, 0.0, 10.0, 10.0, fill(Color::rgb(1.0, 0.0, 0.0)), None);
    assert_eq!(child.visibility(), Visibility::Preview, "the child is NOT outline itself");

    let mut g = GroupElem {
        children: vec![Rc::new(child)],
        common: common(),
        isolated_blending: false,
        knockout_group: false,
    };
    g.common.visibility = Visibility::Outline;

    let mut rec = RecordingPainter::new();
    emit_element(&mut rec, &Element::Group(g), 1.0);
    let cmds = rec.commands();

    assert_eq!(fills(&cmds), 0, "the child's fill must be suppressed by the ANCESTOR's mode");
    assert_eq!(outline_style_of(&cmds).len(), 1, "and it must be outlined instead");
}

/// The other direction: a `Preview` ancestor does not un-outline a child that
/// asked for it. `min` is not "the ancestor wins".
#[test]
fn a_preview_ancestor_does_not_cancel_a_childs_own_outline() {
    let g = GroupElem {
        children: vec![Rc::new(outline_rect())],
        common: common(),
        isolated_blending: false,
        knockout_group: false,
    };
    let mut rec = RecordingPainter::new();
    emit_element(&mut rec, &Element::Group(g), 1.0);
    assert_eq!(fills(&rec.commands()), 0, "the child chose outline; the group does not veto it");
}

/// ⛔ AND AN INVISIBLE CAP STILL STOPS EVERYTHING. `Invisible` orders BELOW
/// `Outline`, so an invisible ancestor must not be turned into an outlined one
/// by the new inheritance -- the failure would be a document that draws its
/// hidden layers as wireframe.
#[test]
fn an_invisible_ancestor_still_paints_nothing() {
    let mut rec = RecordingPainter::new();
    emit_element_with_vis(&mut rec, &outline_rect(), 1.0, Visibility::Invisible);
    assert!(rec.commands().is_empty(),
            "an invisible cap outranks outline: {:?}", rec.commands());
}

/// The router must stop sending outline elements to legacy -- otherwise the
/// lowering above is dead code that no production path can reach.
#[test]
fn the_router_no_longer_routes_outline_to_legacy() {
    let caps = Caps::NONE
        .with(Capability::IsolatedLayers)
        .with(Capability::MaskLayers);
    assert!(!element_needs_legacy(&outline_rect(), caps),
            "outline is lowered on the seam now; routing it to legacy would \
             leave the lowering unreachable");
}

/// ⛔ THE ALPHA STILL RIDES. Outline drops the element's own fill/stroke
/// opacities, but NOT the inherited paint alpha -- `render.rs` uses
/// `base_alpha * stroke_op` with `stroke_op = 1.0`, and `base_alpha` still
/// carries every ancestor's opacity.
#[test]
fn outline_rides_the_inherited_alpha_but_drops_the_elements_own_paint_opacities() {
    let mut rec = RecordingPainter::new();
    emit_element(&mut rec, &outline_rect(), 0.5);
    let strokes = outline_style_of(&rec.commands());
    assert_eq!(strokes.len(), 1);
    assert_eq!(strokes[0].2, 0.5, "the incoming alpha must survive outline mode");
}

// ---------------------------------------------------------------------------
// ROW CV — LIVE ELEMENTS THROUGH THE ROUTER
// ---------------------------------------------------------------------------
//
// ⭐ THE RULING (helm, 2026-09-01 17:24:10): a Live element off the web IS ITS
// EVALUATED OUTPUT THROUGH THE CORE'S OWN CONTRACT — the four `evaluate_with`
// arms `canvas::render` already takes per variant — drawn through the Painter
// as geometry. NEVER a baked snapshot, NEVER a native-specific generator, and a
// generator that cannot complete yields EMPTY (LIVE_ELEMENTS.md §2's uniform
// failure rule).
//
// ⛔ THE ARM THAT ALREADY LOOKED RIGHT WAS RIGHT FOR THE WRONG REASON.
// `emit_element_body`'s `Element::Live(_) => {}` painted nothing before this
// row too — not because the element evaluated to nothing, but because Live was
// unimplemented and the router kept it away. An empty result and an absent
// implementation are indistinguishable from the outside, which is why the
// dangling-reference test below is not redundant with the arm existing: it is
// the only one that can tell them apart.

use crate::document::id_index::{install_paint_context, IdIndex};
use crate::geometry::live::{
    CompoundOperation, CompoundShape, ElementRef, LiveVariant, ReferenceElem, DEFAULT_PRECISION,
};

/// A compound shape with its own paint, as an `Element`.
fn live_union(operands: Vec<Element>, f: Option<Fill>, s: Option<Stroke>) -> Element {
    Element::Live(LiveVariant::CompoundShape(CompoundShape {
        operation: CompoundOperation::Union,
        operands: operands.into_iter().map(Rc::new).collect(),
        fill: f,
        stroke: s,
        common: common(),
    }))
}

/// Two overlapping rects — a union with ONE ring and a shape neither operand
/// has, so a lowering that painted an operand instead of the evaluated output
/// would be visible in the vertex list rather than only in the paint.
fn overlapping_operands() -> Vec<Element> {
    vec![
        rect(0.0, 0.0, 100.0, 100.0, fill(Color::rgb(1.0, 1.0, 0.0)), None),
        rect(50.0, 50.0, 100.0, 100.0, fill(Color::rgb(0.0, 1.0, 1.0)), None),
    ]
}

fn fill_paths(cmds: &[Command]) -> Vec<(&Vec<PathCommand>, &Brush, f64)> {
    cmds.iter()
        .filter_map(|c| match c {
            Command::FillPath { path, brush, paint_alpha, .. } => Some((path, brush, *paint_alpha)),
            _ => None,
        })
        .collect()
}

fn stroke_paths(cmds: &[Command]) -> Vec<(&Vec<PathCommand>, &Brush, &StrokeStyle, f64)> {
    cmds.iter()
        .filter_map(|c| match c {
            Command::StrokePath { path, brush, stroke, paint_alpha } => {
                Some((path, brush, stroke, *paint_alpha))
            }
            _ => None,
        })
        .collect()
}

/// The router must stop sending live geometry to legacy — otherwise the
/// lowering below is unreachable and the Windows app, whose ONLY renderer is
/// `emit_element`, keeps refusing every document that carries one.
///
/// ⚠️ AND TEXT MUST STAY. The clause being edited names three kinds in one
/// `matches!`; deleting the whole clause would silently put `Text` and
/// `TextPath` on a seam that has no shaping vocabulary for them (PH3, not this
/// row). Both halves are asserted so the edit cannot be wider than the ruling.
#[test]
fn the_router_no_longer_routes_live_to_legacy_and_text_still_is() {
    let caps = Caps::NONE
        .with(Capability::IsolatedLayers)
        .with(Capability::MaskLayers);
    let live = live_union(overlapping_operands(), fill(Color::rgb(1.0, 0.0, 0.0)), None);
    assert!(
        !element_needs_legacy(&live, caps),
        "live geometry is lowered on the seam now; routing it to legacy would \
         leave the lowering unreachable and the native walk blind"
    );
    // ⭐ AND THE TEXT CLAUSE HAS NARROWED AGAIN — row DA, 2026-09-01. This arm
    // used to assert that ALL text stayed legacy, with the message "the clause
    // must narrow, not vanish". DA is that narrowing: FLAT AND FEATURE-FREE text
    // converts; everything else still does not. The arm keeps its intent by
    // asserting BOTH SIDES of the new boundary rather than one side of the old.
    let flat = Element::Text(crate::geometry::element::TextElem::from_string(
        1.0, 2.0, "hi", "Arial", 12.0, "normal", "normal", "none", 10.0, 12.0, None, None,
        common(),
    ));
    assert!(
        !element_needs_legacy(&flat, caps),
        "flat, feature-free text lowers on the seam now (row DA); routing it to \
         legacy would leave the lowering unreachable and the Windows app blind \
         to every plain <text> in the corpus"
    );

    // ⛔ "none" IS THE ABSENT VALUE FOR DECORATION, and this element proves the
    // arm above is not passing by accident: `from_string` is handed "none",
    // which a naive `!is_empty()` reads as "has a decoration" -- the bug that
    // kept all four DA documents refusing on the first cut.
    let mut underlined = match flat.clone() {
        Element::Text(t) => t,
        _ => unreachable!(),
    };
    underlined.text_decoration = "underline".into();
    assert!(
        element_needs_legacy(&Element::Text(underlined), caps),
        "a REAL decoration is an extra primitive and stays legacy -- the clause \
         narrowed, it did not vanish"
    );

    let mut tracked = match flat {
        Element::Text(t) => t,
        _ => unreachable!(),
    };
    tracked.letter_spacing = "0.025em".into();
    assert!(
        element_needs_legacy(&Element::Text(tracked), caps),
        "tracking is one of the four features DA explicitly did NOT take"
    );
}

/// ⭐ THE EVALUATED OUTPUT, NOT THE OPERANDS. The union of two overlapping
/// rects is a single 8-vertex ring belonging to NEITHER operand, so this
/// assertion cannot be satisfied by painting an operand and cannot be satisfied
/// by painting a bounding box.
#[test]
fn a_live_compound_shape_paints_its_evaluated_geometry_through_the_painter() {
    let elem = live_union(
        overlapping_operands(),
        fill(Color::rgb(1.0, 0.0, 0.0)),
        Some(stroke(Color::rgb(0.0, 0.0, 1.0), 3.0)),
    );
    let mut rec = RecordingPainter::new();
    emit_element(&mut rec, &elem, 1.0);
    let cmds = rec.commands();

    let fills = fill_paths(cmds);
    assert_eq!(fills.len(), 1, "one fill for the evaluated ring: {cmds:?}");
    assert_eq!(*fills[0].1, Brush::Solid(Color::rgb(1.0, 0.0, 0.0)),
               "the compound's OWN fill, not an operand's yellow or cyan");

    // The union's outline: 8 corners, closed. A lowering that drew an operand
    // would emit 4, and one that drew both would emit two rings.
    let moves = fills[0].0.iter().filter(|c| matches!(c, PathCommand::MoveTo { .. })).count();
    let lines = fills[0].0.iter().filter(|c| matches!(c, PathCommand::LineTo { .. })).count();
    assert_eq!(moves, 1, "the union is ONE ring: {:?}", fills[0].0);
    assert_eq!(lines, 7, "an L-shaped union has 8 vertices: {:?}", fills[0].0);
    assert!(matches!(fills[0].0.last(), Some(PathCommand::ClosePath)),
            "legacy closes every ring before filling: {:?}", fills[0].0);

    let strokes = stroke_paths(cmds);
    assert_eq!(strokes.len(), 1, "one stroke over the same ring: {cmds:?}");
    assert_eq!(strokes[0].0, fills[0].0, "fill and stroke trace ONE path (legacy traces once)");
    assert_eq!(strokes[0].2.width, 3.0);
}

/// A live element with NO paint at all paints nothing — `render.rs` fills only
/// `if live_fill.is_some()` and strokes only `if live_stroke.is_some()`.
/// Without this arm a lowering could emit a transparent fill and no test would
/// see the extra op.
///
/// ⚠️ GREEN AT HEAD TOO, for the same reason as the dangling-reference arm
/// below: "unimplemented" and "nothing to paint" are the same picture. Driven
/// by mutation (emit an unconditional fill), not by red-first.
#[test]
fn a_live_element_with_no_paint_emits_no_ops() {
    let mut rec = RecordingPainter::new();
    emit_element(&mut rec, &live_union(overlapping_operands(), None, None), 1.0);
    assert!(rec.commands().is_empty(), "no paint, no ops: {:?}", rec.commands());
}

/// ⛔ THE UNIFORM FAILURE RULE (LIVE_ELEMENTS.md §2): a reference to an id
/// nothing indexes evaluates to EMPTY, so nothing is painted — not a bounding
/// box, not a placeholder, and NOT a panic.
///
/// ⚠️ THIS ARM IS GREEN AT HEAD AND I AM SAYING SO. Before the row, `Live` was
/// routed to legacy and the body arm painted nothing; after it, the reference
/// resolves to nothing and the body arm paints nothing. The two states AGREE
/// here, so this test is red-first for nothing and proves nothing on its own —
/// it is the tame example, kept and labelled rather than mistaken for evidence.
/// What drives it is the MUTATION pass (an arm that paints a bbox for an
/// unresolvable target, or one that panics), and what makes it meaningful is
/// the tests above it, which force the lowering to exist in the first place.
#[test]
fn a_dangling_reference_paints_nothing() {
    let elem = Element::Live(LiveVariant::Reference(ReferenceElem {
        target: ElementRef("no-such-id".into()),
        transform: None,
        fill: fill(Color::rgb(1.0, 0.0, 0.0)),
        stroke: Some(stroke(Color::rgb(0.0, 0.0, 1.0), 2.0)),
        common: common(),
    }));
    let _guard = install_paint_context(IdIndex::new(), DEFAULT_PRECISION);
    let mut rec = RecordingPainter::new();
    emit_element(&mut rec, &elem, 1.0);
    assert!(rec.commands().is_empty(),
            "a dangling target yields EMPTY, and empty geometry paints nothing: {:?}",
            rec.commands());
}

/// A resolvable target, installed through the SAME core service `canvas::render`
/// installs — this is the row's second half: the router USES the caller-owned
/// paint context rather than carrying an index of its own.
fn indexed(target: Element) -> IdIndex {
    let mut idx = IdIndex::new();
    let id = target.common().id.clone().expect("the fixture's target carries an id");
    idx = idx.insert(id, Rc::new(target));
    idx
}

/// ⭐ FORK F3 — A REFERENCE WITH NO PAINT OF ITS OWN INHERITS ITS TARGET'S.
/// `render.rs` does this for the `Reference` variant and ONLY for it; the
/// inheritance is the one place the four variants differ, so a lowering that
/// treated them uniformly would draw an unpainted instance of a painted master.
#[test]
fn a_reference_inherits_the_targets_paint_when_its_own_is_unset() {
    let mut target = rect(10.0, 10.0, 40.0, 40.0,
                          fill(Color::rgb(0.0, 1.0, 0.0)),
                          Some(stroke(Color::rgb(1.0, 0.0, 1.0), 5.0)));
    target.common_mut().id = Some("m1".into());
    let _guard = install_paint_context(indexed(target), DEFAULT_PRECISION);

    let elem = Element::Live(LiveVariant::Reference(ReferenceElem {
        target: ElementRef("m1".into()),
        transform: None,
        fill: None,
        stroke: None,
        common: common(),
    }));
    let mut rec = RecordingPainter::new();
    emit_element(&mut rec, &elem, 1.0);
    let cmds = rec.commands();

    let fills = fill_paths(cmds);
    assert_eq!(fills.len(), 1, "the resolved geometry is filled: {cmds:?}");
    assert_eq!(*fills[0].1, Brush::Solid(Color::rgb(0.0, 1.0, 0.0)),
               "F3: the unset fill inherits the TARGET's green");
    let strokes = stroke_paths(cmds);
    assert_eq!(strokes.len(), 1);
    assert_eq!(*strokes[0].1, Brush::Solid(Color::rgb(1.0, 0.0, 1.0)),
               "F3: the unset stroke inherits the TARGET's magenta");
    assert_eq!(strokes[0].2.width, 5.0, "the target's stroke rides whole, not just its colour");
}

/// …and an own paint OVERRIDES it. Without this arm a lowering that ALWAYS read
/// the target's paint would pass the test above.
#[test]
fn a_reference_with_its_own_paint_does_not_inherit() {
    let mut target = rect(10.0, 10.0, 40.0, 40.0, fill(Color::rgb(0.0, 1.0, 0.0)), None);
    target.common_mut().id = Some("m1".into());
    let _guard = install_paint_context(indexed(target), DEFAULT_PRECISION);

    let elem = Element::Live(LiveVariant::Reference(ReferenceElem {
        target: ElementRef("m1".into()),
        transform: None,
        fill: fill(Color::rgb(1.0, 0.0, 0.0)),
        stroke: None,
        common: common(),
    }));
    let mut rec = RecordingPainter::new();
    emit_element(&mut rec, &elem, 1.0);
    assert_eq!(*fill_paths(rec.commands())[0].1, Brush::Solid(Color::rgb(1.0, 0.0, 0.0)),
               "an own fill wins over the target's");
}

/// ⭐ THE PRECISION IS READ FROM THE INSTALLED CONTEXT, NOT FROM A CONSTANT.
/// `canvas::render` evaluates at the walk's own `precision` parameter;
/// `emit_element` has no such parameter, so row CV made precision part of the
/// install. A lowering that reached for `DEFAULT_PRECISION` instead would
/// tessellate the same document differently from the web walk at any non-
/// default Boolean-panel setting, and nothing else would be looking.
#[test]
fn the_live_arm_evaluates_at_the_installed_precision() {
    let curved = || {
        vec![Element::Ellipse(EllipseElem {
            cx: 60.0, cy: 60.0, rx: 50.0, ry: 50.0,
            fill: None, stroke: None, common: common(),
            fill_gradient: None, stroke_gradient: None,
        })]
    };
    let verts_at = |precision: f64| -> usize {
        let _guard = install_paint_context(IdIndex::new(), precision);
        let mut rec = RecordingPainter::new();
        emit_element(&mut rec, &live_union(curved(), fill(Color::WHITE), None), 1.0);
        fill_paths(rec.commands())[0].0.len()
    };
    let coarse = verts_at(2.0);
    let fine = verts_at(0.001);
    assert!(
        fine > coarse,
        "a finer installed precision must tessellate the arc into more vertices \
         (coarse={coarse}, fine={fine}); equal counts mean the arm ignored the install"
    );
}

/// ⛔ OUTLINE MODE REACHES LIVE GEOMETRY TOO. `render.rs`'s Live arm branches on
/// `outline` exactly as every other arm does: `apply_outline_style`, then NO
/// fill and a stroke over the evaluated rings. Before this row the outline arm
/// listed `Live` among the kinds that "fall through silently" and justified it
/// by saying the router sent them to legacy — a reason this row removes.
#[test]
fn a_live_element_in_outline_mode_is_one_black_hairline_and_no_fill() {
    let mut elem = live_union(
        overlapping_operands(),
        fill(Color::rgb(1.0, 0.0, 0.0)),
        Some(stroke(Color::rgb(0.0, 0.0, 1.0), 9.0)),
    );
    elem.common_mut().visibility = Visibility::Outline;

    let mut rec = RecordingPainter::new();
    emit_element(&mut rec, &elem, 1.0);
    let cmds = rec.commands();

    assert_eq!(fills(cmds), 0, "outline REPLACES the fill: {cmds:?}");
    let strokes = stroke_paths(cmds);
    assert_eq!(strokes.len(), 1, "exactly one hairline: {cmds:?}");
    assert_eq!(*strokes[0].1, Brush::Solid(Color::rgb(0.0, 0.0, 0.0)),
               "outline is black, not the element's blue");
    assert_eq!(strokes[0].2.width, 1.0, "outline is a 1px hairline, not the element's 9");
    assert!(strokes[0].2.dash.is_empty(), "outline clears the dash");
    let lines = strokes[0].0.iter().filter(|c| matches!(c, PathCommand::LineTo { .. })).count();
    assert_eq!(lines, 7, "the hairline traces the EVALUATED union, not a bbox");
}

/// The inherited half: a live element inside an OUTLINED group outlines too.
/// `emit_element_body` dispatches outline before the leaf arms, so this is the
/// route production actually takes for a Live layer under an outlined group.
#[test]
fn a_live_element_under_an_outlined_group_outlines() {
    let live = live_union(overlapping_operands(), fill(Color::rgb(1.0, 0.0, 0.0)), None);
    let mut g = GroupElem {
        children: vec![Rc::new(live)],
        common: common(),
        isolated_blending: false,
        knockout_group: false,
    };
    g.common.visibility = Visibility::Outline;
    let mut rec = RecordingPainter::new();
    emit_element(&mut rec, &Element::Group(g), 1.0);
    assert_eq!(fills(rec.commands()), 0, "the group's outline reaches the live child");
    assert_eq!(stroke_paths(rec.commands()).len(), 1, "and gives it a hairline");
}

/// The paint alpha compounds through live geometry exactly as it does through a
/// rect: `render.rs` uses `base_alpha * fill_op` / `base_alpha * stroke_op`.
#[test]
fn live_geometry_rides_the_inherited_alpha_and_its_own_paint_opacities() {
    let elem = live_union(
        overlapping_operands(),
        fill_op(Color::rgb(1.0, 0.0, 0.0), 0.5),
        Some({
            let mut s = stroke(Color::rgb(0.0, 0.0, 1.0), 3.0);
            s.opacity = 0.25;
            s
        }),
    );
    let mut rec = RecordingPainter::new();
    emit_element(&mut rec, &elem, 0.4);
    let cmds = rec.commands();
    assert!((fill_paths(cmds)[0].2 - 0.4 * 0.5).abs() < 1e-12,
            "fill alpha = incoming * fill opacity: {:?}", fill_paths(cmds)[0].2);
    assert!((stroke_paths(cmds)[0].3 - 0.4 * 0.25).abs() < 1e-12,
            "stroke alpha = incoming * stroke opacity: {:?}", stroke_paths(cmds)[0].3);
}

/// ⛔ AND THE SUBTREE ROUTER FOLLOWS. `subtree_needs_legacy` is the PRODUCTION
/// router: a masked group holding a live child used to force the whole subtree
/// to legacy, which is how the web app renders it today. After this row it
/// converts — a named production route change, not a discovered one.
#[test]
fn a_subtree_holding_a_live_element_no_longer_forces_legacy() {
    let caps = Caps::NONE
        .with(Capability::IsolatedLayers)
        .with(Capability::MaskLayers);
    let g = GroupElem {
        children: vec![
            Rc::new(rect(0.0, 0.0, 10.0, 10.0, fill(Color::WHITE), None)),
            Rc::new(live_union(overlapping_operands(), fill(Color::WHITE), None)),
        ],
        common: common(),
        isolated_blending: false,
        knockout_group: false,
    };
    assert!(!subtree_needs_legacy(&Element::Group(g), caps),
            "a live descendant no longer drags its whole subtree to legacy");
}

/// ⛔ ROW EH — THE RULE THE RINGS ARE READ UNDER, AND WHY IT IS NOT NON-ZERO.
///
/// This test was written on 09/02 as a measured NEGATIVE: `ref_live`'s
/// `SubtractFront` evaluates to two CO-ORIENTED rings, so it asserted that the
/// seam emits `NonZero` and the shape paints solid. That reading of the
/// ORIENTATION was correct and is kept below — the rings really do share a
/// winding direction, and that is exactly why the rule matters here. What was
/// wrong was the conclusion: it treated "both walks agree" as the whole
/// contract and left the shared answer unexamined.
///
/// ⚖️ THE RULE IS NOT THE RENDERER'S TO PICK. BOOLEAN.md's carried-rule law
/// (RULED 2026-07-26, clause 4) makes a generated boolean result declare
/// EVEN-ODD, named by `boolean::RESULT_FILL_RULE`, precisely so a hole survives
/// a sweep that emits inconsistent winding. Every ring set reaching a live
/// element's paint comes out of that layer. So co-orientation is not evidence
/// that the shape is solid — under the rule its producer declares, two nested
/// co-oriented rings are a HOLE, and reading them under non-zero refills it.
///
/// ⛔ THE OLD COMMENT'S "`CompoundShape` carries no `fill_rule` field for either
/// path to consult" WAS THE FINDING, READ AS AN EXCUSE. It is true, and it is
/// the reason the 07/26 wave — which repaired the destructive boolean by
/// stamping the constant onto the `Path` element it emits — could not reach
/// this arm. A live compound emits no element to stamp. The rule therefore has
/// to come from the constant directly, which is what the seam now does.
///
/// This test states the golden's meaning rather than leaving it inferred: if
/// the evaluator ever starts reversing hole rings, or the declared rule moves,
/// this reds and says which of the two changed.
#[test]
fn the_subtract_rings_are_co_oriented_and_are_read_under_the_declared_even_odd_rule() {
    /// Twice the signed area — positive and negative are opposite orientations.
    fn signed_area2(ring: &[(f64, f64)]) -> f64 {
        let mut a = 0.0;
        for i in 0..ring.len() {
            let (x0, y0) = ring[i];
            let (x1, y1) = ring[(i + 1) % ring.len()];
            a += x0 * y1 - x1 * y0;
        }
        a
    }
    let hole = Element::Live(LiveVariant::CompoundShape(CompoundShape {
        operation: CompoundOperation::SubtractFront,
        operands: vec![
            Rc::new(rect(200.0, 0.0, 120.0, 120.0, None, None)),
            Rc::new(rect(230.0, 30.0, 60.0, 60.0, None, None)),
        ],
        fill: fill(Color::WHITE),
        stroke: None,
        common: common(),
    }));
    let mut rec = RecordingPainter::new();
    emit_element(&mut rec, &hole, 1.0);
    let cmds = rec.commands();
    let fills = fill_paths(cmds);
    assert_eq!(fills.len(), 1, "two rings, ONE path, one fill: {cmds:?}");
    let winding = cmds.iter().find_map(|c| match c {
        Command::FillPath { winding, .. } => Some(*winding),
        _ => None,
    });
    assert_eq!(
        winding, Some(FillRule::from(crate::algorithms::boolean::RESULT_FILL_RULE)),
        "the seam must declare the rule the ALGORITHM LAYER declares for its own \
         output (BOOLEAN.md clause 4), not the one its language's bare fill \
         happens to default to"
    );

    // Rebuild the rings from the emitted path and compare their orientations.
    let mut rings: Vec<Vec<(f64, f64)>> = Vec::new();
    for c in fills[0].0 {
        match c {
            PathCommand::MoveTo { x, y } => rings.push(vec![(*x, *y)]),
            PathCommand::LineTo { x, y } => rings.last_mut().unwrap().push((*x, *y)),
            _ => {}
        }
    }
    assert_eq!(rings.len(), 2, "an outer ring and an inner one: {rings:?}");
    let (outer, inner) = (signed_area2(&rings[0]), signed_area2(&rings[1]));
    assert!(
        outer * inner > 0.0,
        "MEASURED: the subtract's rings share an orientation (outer={outer}, \
         inner={inner}). That is WHY the declared rule is load-bearing: under \
         even-odd these two rings are a ring and a hole, and under non-zero the \
         inner one has winding ±2 and fills. If this ever flips — the evaluator \
         starting to reverse hole rings — the rule stops being the only thing \
         holding the hole open, and the goldens must be re-photographed."
    );
}

/// ⛔ A ONE-POINT RING IS SKIPPED, AND THIS ARM EXISTS BECAUSE A MUTANT SURVIVED
/// WITHOUT IT. `live_rings_path` skips any ring with fewer than two points —
/// `render.rs` skips the same ones with the same test — and weakening that to
/// `is_empty()` changed NO test in the first mutation pass. So the guard was a
/// faithful port of legacy that nothing drove, which is the state a guard rots
/// in.
///
/// 📌 IT IS REACHABLE, MEASURED RATHER THAN ASSUMED: a `Polygon` operand with a
/// single point evaluates to `[[(5,5)]]` — the boolean evaluator hands the ring
/// through rather than collapsing it — so the skip is live code on both walks.
/// A degenerate `MoveTo`+`ClosePath` would otherwise reach the backend as a real
/// fill op, and Direct2D and Canvas2D need not agree on what they do with one.
///
/// ⚠️ Green at HEAD as well (the arm painted nothing there either), so this is
/// not red-first for anything — it is the mutation's fixture, and it is labelled
/// as such rather than counted as a red.
#[test]
fn a_ring_with_one_point_is_skipped_and_emits_no_degenerate_path() {
    use crate::geometry::element::PolygonElem;
    let single_point = Element::Polygon(PolygonElem {
        points: vec![(5.0, 5.0)],
        fill: None,
        stroke: None,
        common: common(),
        fill_gradient: None,
        stroke_gradient: None,
    });
    let elem = live_union(vec![single_point], fill(Color::WHITE), None);
    let mut rec = RecordingPainter::new();
    emit_element(&mut rec, &elem, 1.0);
    assert!(
        rec.commands().is_empty(),
        "a one-point ring has no edge to trace; emitting MoveTo+ClosePath would \
         hand the backend a degenerate fill: {:?}",
        rec.commands()
    );
}

// ---------------------------------------------------------------------------
// RP3 — the non-centre ellipse stroke (ruled 2026-09-01, option (a))
// ---------------------------------------------------------------------------

use super::ELLIPSE_KAPPA;

/// One point on a cubic at parameter `t`.
fn cubic_at(p0: (f64, f64), c1: (f64, f64), c2: (f64, f64), p3: (f64, f64), t: f64) -> (f64, f64) {
    let u = 1.0 - t;
    let (a, b, c, d) = (u * u * u, 3.0 * u * u * t, 3.0 * u * t * t, t * t * t);
    (a * p0.0 + b * c1.0 + c * c2.0 + d * p3.0,
     a * p0.1 + b * c1.1 + c * c2.1 + d * p3.1)
}




/// ⚰️ **RP3's TOMBSTONE.** This arm used to assert the OPPOSITE of what it now
/// asserts, and the rename is deliberate so the diff shows the exception dying
/// rather than a test quietly disappearing.
///
/// It read: *"a non-centre stroke cannot be an arc — it needs the clip"*, and
/// it pinned the four-cubic ring plus a clip at 2× width. The 2026-09-02
/// council ruling (EXACT ELLIPSE EVERYWHERE) retired that: the align rides the
/// arc and the backend clips with its own exact conic.
///
/// ⭐ WHAT SURVIVES UNCHANGED IS THE ROUTING ASSERTION, and it is the reason
/// this test was converted rather than deleted: a non-centre ellipse must NOT
/// go to legacy. That claim is independent of how the stroke is expressed, and
/// deleting the file's only copy of it would have been a silent loss.
#[test]
fn a_non_centre_ellipse_is_lowered_and_keeps_the_exact_conic() {
    let e = EllipseElem {
        cx: 50.0, cy: 50.0, rx: 40.0, ry: 25.0,
        fill: fill(Color::rgb(0.2, 0.4, 0.8)),
        stroke: Some(stroke_aligned(Color::BLACK, 6.0, StrokeAlign::Inside)),
        common: common(), fill_gradient: None, stroke_gradient: None,
    };
    let elem = Element::Ellipse(e.clone());
    assert!(!element_needs_legacy(&elem, all_caps()),
            "a non-centre ellipse is lowered on the seam; routing it to legacy              leaves the lowering unreachable");

    let mut rec = RecordingPainter::new();
    emit_element(&mut rec, &elem, 1.0);
    let cmds = rec.commands();

    assert_eq!(cmds.iter().filter(|c| matches!(c, Command::FillEllipseArc { .. })).count(), 1,
               "the fill was always an exact arc: {cmds:?}");
    assert_eq!(cmds.iter().filter(|c| matches!(c, Command::StrokeEllipseArc { .. })).count(), 1,
               "and NOW SO IS THE STROKE -- this is the line that flipped: {cmds:?}");
    assert!(!cmds.iter().any(|c| matches!(c, Command::Clip { .. })),
            "no clip crosses the seam any more -- amendment A5 stands: {cmds:?}");
}


// ---------------------------------------------------------------------------
// ROW DR capability 1 — segmented text (tspans)
// ---------------------------------------------------------------------------

fn tspan(content: &str, weight: Option<&str>, size: Option<f64>) -> crate::geometry::tspan::Tspan {
    let mut t = crate::geometry::tspan::Tspan::default_tspan();
    t.content = content.to_string();
    t.font_weight = weight.map(|w| w.to_string());
    t.font_size = size;
    t
}

fn segmented(tspans: Vec<crate::geometry::tspan::Tspan>) -> Element {
    let mut e = crate::geometry::element::TextElem::from_string(
        10.0, 20.0, "", "sans-serif", 12.0, "normal", "normal", "none", 10.0, 12.0, None, None,
        common(),
    );
    e.fill = fill(Color::BLACK);
    e.tspans = tspans;
    Element::Text(e)
}

/// The x of each recorded FastRun, in order.
fn run_origins(cmds: &[Command]) -> Vec<f64> {
    cmds.iter()
        .filter_map(|c| match c {
            Command::DrawTextRun { run: crate::painter::TextRun::FastRun { x, .. }, .. } => Some(*x),
            _ => None,
        })
        .collect()
}

/// ⭐ ROW DR capability 1: a segmented text emits ONE RUN PER TSPAN, and the
/// second starts where the first ends.
///
/// ⛔ GATED ON THE BACKEND THAT HAS A REAL MEASURER, and the gate is the POINT
/// rather than a convenience. Row DR routes segmented text on the presence of
/// `try_make_measurer`, which is `None` off Direct2D BY CONSTRUCTION — so on
/// every other platform the correct behaviour is to REFUSE, and that is
/// asserted by `segmented_stays_legacy_without_a_real_measurer` below.
///
/// 📌 Measured the hard way: the first cut of these arms was ungated and went
/// green on this box while failing on the ubuntu and macOS lanes. Tests written
/// where the author is are exactly the class this seat keeps finding in other
/// people's instruments.
#[cfg(all(feature = "d2d", windows))]
#[test]
fn segmented_text_emits_one_run_per_tspan_at_measured_offsets() {
    let elem = segmented(vec![tspan("Hello ", None, None), tspan("world", Some("bold"), None)]);
    assert!(!element_needs_legacy(&elem, all_caps()),
            "feature-free tspans with a resolvable face lower on the seam now");

    let mut rec = RecordingPainter::new();
    emit_element(&mut rec, &elem, 1.0);
    let xs = run_origins(rec.commands());
    assert_eq!(xs.len(), 2, "one run per tspan: {:?}", rec.commands());
    assert_eq!(xs[0], 10.0, "the first run starts at the element's x");
    assert!(xs[1] > xs[0] + 20.0,
            "the second run must start a MEASURED distance along ({:?}) -- \
             equal to the first means the pen never advanced", xs);
}

/// ⛔⛔ THE MEASURER MUST USE EACH TSPAN'S OWN FONT — AND THIS ARM EXISTS
/// BECAUSE A MUTATION PASS PROVED THE COMMENT WAS NOT A GUARD.
///
/// `emit_segmented_text` says, in as many words, that hoisting one measurer out
/// of the loop "would reintroduce" the weight-blindness row DQ measured in the
/// stub. I then wrote a suite in which **a mutant that hoisted the PARENT
/// font's measurer passed all 3,169 tests** — because both corpus fixtures put
/// the OVERRIDE on the SECOND tspan, whose width nothing advances by.
///
/// ⇒ The fixture has to put the override FIRST. Here tspan[0] is 36pt against a
/// 12pt parent: measured with its own font it advances ~3× further than measured
/// with the parent's, so the second run's origin separates the two readings by a
/// wide margin.
#[cfg(all(feature = "d2d", windows))]
#[test]
fn the_pen_advances_by_each_tspans_own_font_not_the_parents() {
    // tspan[0] is THREE TIMES the parent size; tspan[1] inherits.
    let elem = segmented(vec![tspan("MMMM", None, Some(36.0)), tspan("x", None, None)]);
    let mut rec = RecordingPainter::new();
    emit_element(&mut rec, &elem, 1.0);
    let xs = run_origins(rec.commands());
    assert_eq!(xs.len(), 2);

    // What the parent's 12pt font would have advanced by, for the same text.
    let parent_advance = crate::text_measure::try_make_measurer("normal normal sans-serif", 12.0)
        .expect("resolve")("MMMM");
    let own_advance = crate::text_measure::try_make_measurer("normal normal sans-serif", 36.0)
        .expect("resolve")("MMMM");
    assert!(own_advance > parent_advance * 2.0,
            "the fixture must separate the two readings: own={own_advance:.3} \
             parent={parent_advance:.3}");

    let actual = xs[1] - xs[0];
    assert!((actual - own_advance).abs() < 1.0,
            "the pen advanced {actual:.3}; tspan[0]'s OWN font gives \
             {own_advance:.3} and the parent's gives {parent_advance:.3} -- \
             matching the parent means one measurer was hoisted out of the loop");
}

/// ⛔ AND THE ROUTER STILL REFUSES A TSPAN FEATURE THIS LOWERING DOES NOT CARRY.
/// The clause narrowed; it did not vanish.
#[test]
fn a_tspan_feature_row_dr_did_not_take_still_stays_legacy() {
    for (label, mutate) in [
        ("rotate", (|t: &mut crate::geometry::tspan::Tspan| t.rotate = Some(15.0))
            as fn(&mut crate::geometry::tspan::Tspan)),
        ("dx", |t: &mut crate::geometry::tspan::Tspan| t.dx = Some(0.5)),
        ("baseline_shift", |t: &mut crate::geometry::tspan::Tspan| t.baseline_shift = Some(2.0)),
        ("decoration", |t: &mut crate::geometry::tspan::Tspan| {
            t.text_decoration = Some(vec!["underline".to_string()])
        }),
    ] {
        let mut second = tspan("world", Some("bold"), None);
        mutate(&mut second);
        let elem = segmented(vec![tspan("Hello ", None, None), second]);
        assert!(element_needs_legacy(&elem, all_caps()),
                "a tspan carrying {label} is NOT in row DR and must stay legacy");
    }
    // ⛔ THE CONTROL IS PLATFORM-DEPENDENT AND SO IT IS SPLIT OUT, not deleted:
    // "a feature-free segmented text converts" is true only where a real
    // measurer exists. Both halves are asserted, one per platform, below.
}

/// ⛔ "FEATURE-FREE" DOES NOT MEAN "NO OVERRIDES AT ALL". `render_is_flat()` is
/// true when EVERY tspan has no overrides, so a two-tspan text with none is
/// still FLAT and never reaches the segmented walk. The fixtures below give the
/// second tspan a benign FONT override -- exactly what the corpus does
/// (`text_with_tspans.svg`, `setup_text_ab_bold_b.svg` both use
/// `font-weight="bold"`) -- which makes them genuinely segmented while carrying
/// none of the five features row DR left on legacy.
///
/// 📌 Found by running the non-d2d lane locally after CI red: my first
/// "feature-free segmented" fixture had no overrides, so it was flat, converted
/// as flat, and the arm asserting it stays legacy failed for a reason that had
/// nothing to do with the measurer.
///
/// The control for the arm above, where a real measurer exists: without any of
/// those features a segmented text DOES convert — or that loop would be passing
/// because segmented text is refused wholesale.
#[cfg(all(feature = "d2d", windows))]
#[test]
fn a_feature_free_segmented_text_converts_where_a_measurer_exists() {
    let plain = segmented(vec![tspan("Hello ", None, None), tspan("world", Some("bold"), None)]);
    assert!(!matches!(&plain, Element::Text(t) if t.render_is_flat()),
            "the fixture must actually BE segmented, or this arm tests the flat path");
    assert!(!element_needs_legacy(&plain, all_caps()));
}

/// ⛔ AND THE OTHER SIDE OF THE SAME RULE: with NO real measurer, segmented text
/// STAYS LEGACY.
///
/// This is row DR's fail-closed law expressed as a platform property rather than
/// as a `cfg` nobody checks. A segmented walk POSITIONS by measured widths, so a
/// backend without metrics must not attempt it — and off Direct2D
/// `try_make_measurer` is `None` by construction, which is what keeps the web
/// build on its legacy path with no `cfg` in the router at all.
#[cfg(not(all(feature = "d2d", windows)))]
#[test]
fn segmented_stays_legacy_without_a_real_measurer() {
    let plain = segmented(vec![tspan("Hello ", None, None), tspan("world", Some("bold"), None)]);
    assert!(!matches!(&plain, Element::Text(t) if t.render_is_flat()),
            "the fixture must actually BE segmented, or this arm tests the flat path");
    assert!(element_needs_legacy(&plain, all_caps()),
            "with no real measurer, segmented text must stay legacy rather than              lay runs out against metrics that do not exist");
}

// ---------------------------------------------------------------------------
// ROW DR capability 2 — type on a path
// ---------------------------------------------------------------------------

fn text_path(d: Vec<PathCommand>, tspans: Vec<crate::geometry::tspan::Tspan>) -> Element {
    Element::TextPath(crate::geometry::element::TextPathElem {
        d,
        tspans,
        start_offset: 0.0,
        font_family: "sans-serif".into(),
        font_size: 16.0,
        font_weight: "normal".into(),
        font_style: "normal".into(),
        // "none" is the CSS keyword for NO decoration -- the same convention row
        // DA had to learn the hard way, and the same one `draws_decoration_str`
        // tests for by token.
        text_decoration: "none".into(),
        text_transform: String::new(),
        font_variant: String::new(),
        baseline_shift: String::new(),
        line_height: String::new(),
        letter_spacing: String::new(),
        xml_lang: String::new(),
        aa_mode: String::new(),
        rotate: String::new(),
        horizontal_scale: String::new(),
        vertical_scale: String::new(),
        kerning: String::new(),
        fill: fill(Color::BLACK),
        stroke: None,
        common: common(),
    })
}

/// A straight horizontal segment — the simplest possible carrier.
fn flat_path(len: f64) -> Vec<PathCommand> {
    vec![
        PathCommand::MoveTo { x: 0.0, y: 50.0 },
        PathCommand::LineTo { x: len, y: 50.0 },
    ]
}

/// Every `push_state` transform recorded, in order — one per placed glyph.
fn glyph_frames(cmds: &[Command]) -> Vec<Transform> {
    cmds.iter()
        .filter_map(|c| match c {
            Command::PushState { transform } => Some(*transform),
            _ => None,
        })
        .collect()
}

/// ⭐ THE STRAIGHT-LINE ARM ROW DQ NAMED, AND IT COMES FIRST DELIBERATELY: on a
/// horizontal segment the tangent is constant, so a failure here names the
/// MEASURER and not the tangent maths. Isolating the two is the whole reason
/// this arm exists beside the curved one.
#[cfg(all(feature = "d2d", windows))]
#[test]
fn glyphs_on_a_straight_path_advance_by_their_own_measured_widths() {
    let mut t = crate::geometry::tspan::Tspan::default_tspan();
    t.content = "il".into(); // a narrow glyph then a taller one
    let elem = text_path(flat_path(400.0), vec![t]);
    assert!(!element_needs_legacy(&elem, all_caps()),
            "a single-font, feature-free type-on-path lowers now");

    let mut rec = RecordingPainter::new();
    emit_element(&mut rec, &elem, 1.0);
    let frames = glyph_frames(rec.commands());
    assert_eq!(frames.len(), 2, "one frame per glyph: {:?}", rec.commands());

    // The tangent is constant on a straight run, so every frame is a pure
    // translation: a == 1, b == 0.
    for f in &frames {
        assert!((f.a - 1.0).abs() < 1e-6 && f.b.abs() < 1e-6,
                "a horizontal path must give an unrotated frame, got {f:?}");
    }

    // ⛔ AND THE SECOND GLYPH SITS A MEASURED DISTANCE ALONG, not a constant.
    // 'i' is one of the narrowest glyphs there is; the old stub gave every
    // character font_size * 0.55 = 8.8 at this size.
    let m = crate::text_measure::try_make_measurer("normal normal sans-serif", 16.0)
        .expect("resolve");
    let (wi, wl) = (m("i"), m("l"));
    // Each glyph is centred on its own span, so the gap between frame origins is
    // half of each: (wi + wl) / 2.
    let gap = frames[1].e - frames[0].e;
    assert!((gap - (wi + wl) / 2.0).abs() < 0.5,
            "glyph 2 sits {gap:.3} along; its own metrics give {:.3}. The stub \
             would give 8.800 for BOTH glyphs.", (wi + wl) / 2.0);

    // ⛔⛔ EACH GLYPH SITS ON ITS OWN MIDPOINT, NOT ITS LEADING EDGE — and this
    // assertion exists because a mutation pass proved nothing else caught it.
    //
    // The reference places at `(offset + w/2) / total`, centring the glyph on
    // the span it occupies. Placing at `offset / total` instead shifts every
    // glyph half its own width back along the path — and on a curve changes the
    // tangent each is rotated by. A mutant doing exactly that passed all 3,177
    // tests: the GAP between consecutive glyphs is identical either way, so only
    // the FIRST glyph's ABSOLUTE position can see it.
    //
    // This path starts at x = 0, so glyph one belongs at half its own width.
    assert!((frames[0].e - wi / 2.0).abs() < 0.5,
            "glyph 1 sits at {:.3}; centred on its own span it belongs at {:.3} \
             (half of 'i'). ~0 means it was placed at its LEADING EDGE and the \
             whole run is half a glyph out.", frames[0].e, wi / 2.0);
}

/// ⛔ ON A CURVE THE FRAMES MUST ROTATE, and each differently. A lowering that
/// placed glyphs at the right points but never read the tangent would pass the
/// straight-line arm above and fail here — which is exactly why both exist.
#[cfg(all(feature = "d2d", windows))]
#[test]
fn glyphs_on_a_curve_are_rotated_to_the_tangent_and_no_two_alike() {
    let mut t = crate::geometry::tspan::Tspan::default_tspan();
    t.content = "Hello Path".into();
    // text_path_basic.svg's own arch.
    let arch = vec![
        PathCommand::MoveTo { x: 0.0, y: 66.6667 },
        PathCommand::CurveTo {
            x1: 0.0, y1: 0.0, x2: 133.3333, y2: 0.0, x: 133.3333, y: 66.6667,
        },
    ];
    let elem = text_path(arch, vec![t]);
    let mut rec = RecordingPainter::new();
    emit_element(&mut rec, &elem, 1.0);
    let frames = glyph_frames(rec.commands());
    assert!(frames.len() >= 8, "most of the run must fit: {} frames", frames.len());

    // The first glyph climbs, the last descends: their tangents have opposite
    // vertical sense. That is the arch, and no constant rotation can produce it.
    // ⛔ THE TANGENT MUST SWEEP, MONOTONICALLY. Measured on this arch at 16pt,
    // "Hello Path" occupies the early CLIMBING half, so every frame leans the
    // same way (`b < 0`) while flattening toward the apex: b runs -0.986 to
    // -0.258 and `e` advances the whole time.
    //
    // ⚠️ MY FIRST DRAFT ASSERTED THE LAST GLYPH DESCENDS (`b > 0`) and was
    // simply wrong — the run covers ~39 % of the path and never reaches the far
    // side. Asserting the SWEEP instead is both true and stronger: a lowering
    // that read the tangent once and reused it gives an identical b every time,
    // which no tolerance can hide.
    for f in &frames {
        assert!(f.b < 0.0, "every glyph leans up the climbing half, got b={:.4}", f.b);
    }
    for w in frames.windows(2) {
        assert!(w[1].b > w[0].b,
                "the tangent must flatten monotonically: {:.4} then {:.4}", w[0].b, w[1].b);
        assert!(w[1].e > w[0].e,
                "and the pen must advance: {:.3} then {:.3}", w[0].e, w[1].e);
    }
    let sweep = frames.last().unwrap().b - frames.first().unwrap().b;
    assert!(sweep > 0.5,
            "the frames must actually rotate across the run (sweep {sweep:.3}); a              tangent read once and reused gives a sweep of 0");

    // ⛔ AND THE FRAMES MUST BE DISTINCT. Identical rotations would mean the
    // tangent was read once and reused.
    for w in frames.windows(2) {
        assert!((w[0].b - w[1].b).abs() > 1e-9 || (w[0].e - w[1].e).abs() > 1e-9,
                "two consecutive glyph frames are identical: {:?}", w);
    }
}

/// ⭐ THE UNION CASE — `text_path_with_tspans.svg`. Per-tspan fonts on a path:
/// the measurer is needed at RUN granularity to pick each tspan's font AND at
/// GLYPH granularity to place along the curve, and the pen carries ACROSS runs.
#[cfg(all(feature = "d2d", windows))]
#[test]
fn a_tspan_font_override_on_a_path_changes_where_later_glyphs_land() {
    let mk = |second_size: Option<f64>| {
        let mut a = crate::geometry::tspan::Tspan::default_tspan();
        a.content = "MMMM".into();
        a.font_size = second_size; // the FIRST run carries the override
        let mut b = crate::geometry::tspan::Tspan::default_tspan();
        b.content = "x".into();
        text_path(flat_path(2000.0), vec![a, b])
    };
    let frames_of = |e: &Element| {
        let mut rec = RecordingPainter::new();
        emit_element(&mut rec, e, 1.0);
        glyph_frames(rec.commands())
    };

    let plain = frames_of(&mk(None));
    let big = frames_of(&mk(Some(48.0)));
    assert_eq!(plain.len(), 5, "MMMM + x");
    assert_eq!(big.len(), 5);

    // The final glyph belongs to the SECOND tspan, whose font is unchanged; only
    // the pen it starts from differs, because the FIRST run got wider.
    let plain_last = plain.last().unwrap().e;
    let big_last = big.last().unwrap().e;
    assert!(big_last > plain_last * 2.0,
            "a 48pt first run must push the final glyph far further along \
             ({big_last:.3} vs {plain_last:.3}) -- equal means one measurer was \
             used for every tspan");
}

/// ⛔ THE ROUTER STILL REFUSES WHAT ROW DR DID NOT TAKE. The clause narrowed.
#[test]
fn a_type_on_path_feature_row_dr_did_not_take_stays_legacy() {
    let mut base = crate::geometry::tspan::Tspan::default_tspan();
    base.content = "hi".into();

    // An empty path, and empty content, both paint nothing either way.
    assert!(element_needs_legacy(&text_path(vec![], vec![base.clone()]), all_caps()),
            "an empty path has nowhere to place glyphs");
    let empty = crate::geometry::tspan::Tspan::default_tspan();
    assert!(element_needs_legacy(&text_path(flat_path(100.0), vec![empty]), all_caps()),
            "empty content places nothing");

    // A real decoration is an extra primitive that must follow the CURVE.
    let Element::TextPath(mut e) = text_path(flat_path(100.0), vec![base.clone()]) else {
        unreachable!()
    };
    e.text_decoration = "underline".into();
    assert!(element_needs_legacy(&Element::TextPath(e), all_caps()),
            "a curved underline is not in row DR");

    // A tspan feature the segmented walk also refuses.
    let mut rotated = base.clone();
    rotated.rotate = Some(20.0);
    assert!(element_needs_legacy(&text_path(flat_path(100.0), vec![rotated]), all_caps()),
            "a rotated tspan is not in row DR");
}

// -- RP3, retired ------------------------------------------------------------

/// ⭐ THE CAPTAIN'S RULING, AS AN ARM: **EXACT ELLIPSE EVERYWHERE.** A
/// non-centre-aligned ellipse stroke must describe the SAME CONIC a centre one
/// does -- no bézier ring anywhere above the rasteriser.
///
/// ⚖️ THIS ARM IS R4's EXCEPTION BEING SPENT DOWN TO ZERO. RP3 (ruled
/// 2026-09-01) granted exactly one place where the seam changes WHAT SHAPE is
/// drawn rather than how ops are expressed, bounded at
/// `ELLIPSE_BEZIER_MAX_RADIAL_DEVIATION`. The 09/02 council ruling supersedes
/// it: the approximation belongs at the RASTERISER, invisible above it, and
/// both live backends can clip to a true ellipse natively. So the exception is
/// retired rather than re-bounded, and R4 goes back to having none.
///
/// ⛔ THE CENTRE CASE IS THE POSITIVE CONTROL. Without it this arm would pass
/// on a seam that had stopped emitting ellipse arcs altogether.
#[test]
fn a_non_centre_ellipse_stroke_describes_the_same_conic_as_a_centre_one() {
    fn arc_of(align: StrokeAlign) -> crate::painter::EllipseArc {
        let mut e = plain_ellipse_elem();
        e.stroke = Some(stroke_aligned(Color::BLACK, 6.0, align));
        let cmds = ops(&Element::Ellipse(e), 1.0);
        let arcs: Vec<_> = cmds.iter().filter_map(|c| match c {
            Command::StrokeEllipseArc { arc, .. } => Some(*arc),
            _ => None,
        }).collect();
        assert!(
            !cmds.iter().any(|c| matches!(c, Command::StrokePath { .. })),
            "{align:?}: an ellipse stroke must not lower to a PATH -- that is              the bézier ring the ruling forbids above the rasteriser. Got {cmds:?}"
        );
        assert_eq!(arcs.len(), 1, "{align:?}: exactly one stroked arc, got {cmds:?}");
        arcs[0]
    }

    let centre = arc_of(StrokeAlign::Center);
    let inside = arc_of(StrokeAlign::Inside);
    let outside = arc_of(StrokeAlign::Outside);

    assert_eq!(inside, centre, "an inside stroke describes the same conic");
    assert_eq!(outside, centre, "and so does an outside one");

    // And it is the ELEMENT's conic, not some derived one: the offset curve of
    // an ellipse is NOT an ellipse, so a seam that tried to bake the alignment
    // into the radii would be wrong in a way equality alone would not catch.
    let e = plain_ellipse_elem();
    assert_eq!((centre.cx, centre.cy, centre.rx, centre.ry), (e.cx, e.cy, e.rx, e.ry));
}

/// ⛔ AND THE ALIGNMENT MUST STILL BE CARRIED — retiring the ring must not
/// quietly retire the alignment with it.
///
/// ⚠️ THIS ARM ENCODED THE WRONG DESIGN ON ITS FIRST WRITING, and the red is
/// what showed me. I first asserted a VISIBLE `push_state · clip · stroke at 2×
/// · pop_state` in the display list — which is option (a) of my fork, an
/// ellipse-clip entry that repeals A5. The recommendation I filed and am
/// building is (c): the align rides the ARC, A5 survives verbatim, and the
/// clip-then-double happens inside the backend where an exact conic already
/// lives. Two arms cannot encode two designs, so this one moved to (c).
///
/// ⇒ **The display list for an aligned ellipse stroke is ONE command.** The 2×
/// width and the clip are the backend's business and are not expressible here,
/// which is precisely what keeps `Painter::clip` path-only.
#[test]
fn a_non_centre_ellipse_stroke_carries_its_align_and_nothing_else() {
    for align in [StrokeAlign::Inside, StrokeAlign::Outside] {
        let mut e = plain_ellipse_elem();
        e.stroke = Some(stroke_aligned(Color::BLACK, 6.0, align));
        let cmds = ops(&Element::Ellipse(e), 1.0);

        assert!(!cmds.iter().any(|c| matches!(c, Command::Clip { .. })),
                "{align:?}: no clip crosses the seam for an ellipse -- A5 stands: {cmds:?}");
        let (w, a) = cmds.iter().find_map(|c| match c {
            Command::StrokeEllipseArc { stroke, align, .. } => Some((stroke.width, *align)),
            _ => None,
        }).expect("a stroked arc");
        assert_eq!(w, 6.0,
                   "{align:?}: the AUTHORED width crosses, not a doubled one --                     doubling is the backend's half of the lowering");
        assert_eq!(a, align, "and the align is what tells it to do that half");
    }
}

/// ⛔ THE CROSS-LANGUAGE COMPATIBILITY DECISION, PINNED — because a mutant that
/// emitted `align` UNCONDITIONALLY survived every other arm in this file.
///
/// This display list serialises to the corpus JSON the Swift port replays.
/// Every scene pinned before 2026-09-02 is centre-aligned, so emitting the new
/// key always would rewrite all of them and red another port's lane over a
/// value carrying no new information. The rule is: **centre emits nothing, and
/// only a non-centre align appears.**
///
/// Nothing else tested that. The lane that would have caught it is on another
/// platform and reds a day later, in someone else's PR.
#[test]
fn a_centre_align_adds_no_key_to_the_corpus_json() {
    fn json_of(align: StrokeAlign) -> String {
        let mut e = plain_ellipse_elem();
        e.stroke = Some(stroke_aligned(Color::BLACK, 6.0, align));
        let mut rec = RecordingPainter::new();
        emit_element(&mut rec, &Element::Ellipse(e), 1.0);
        rec.to_canonical_json()
    }
    assert!(!json_of(StrokeAlign::Center).contains("align"),
            "a centre stroke must serialise EXACTLY as it did before this node");
    assert!(json_of(StrokeAlign::Inside).contains("\"align\""),
            "and a non-centre one must carry the key, or the picture is lost");
    assert!(json_of(StrokeAlign::Inside).contains("inside"));
    assert!(json_of(StrokeAlign::Outside).contains("outside"));
}

/// ⛔ AN OUTLINED ELLIPSE'S GEOMETRY, WHICH NOTHING ASSERTED.
///
/// Found by a mutant, not by reading: scaling `rx` by 0.9 in the outline arm of
/// `emit_element` passed **the entire suite** — 2,728 tests on the native lane,
/// zero reds. Outline mode drew an ellipse of any size it liked.
///
/// It is pre-existing and not RP3's doing (the outline arm predates it), but it
/// is exactly the shape of the "no pixel can fail" census, and closing it cost
/// less than writing it up.
#[test]
fn an_outlined_ellipse_draws_the_elements_own_conic() {
    let mut e = plain_ellipse_elem();
    e.common.visibility = Visibility::Outline;
    let src = e.clone();
    let cmds = ops(&Element::Ellipse(e), 1.0);

    let arcs: Vec<_> = cmds.iter().filter_map(|c| match c {
        Command::StrokeEllipseArc { arc, .. } => Some(*arc),
        _ => None,
    }).collect();
    assert_eq!(arcs.len(), 1, "an outlined ellipse is one stroked arc: {cmds:?}");
    assert_eq!(
        (arcs[0].cx, arcs[0].cy, arcs[0].rx, arcs[0].ry),
        (src.cx, src.cy, src.rx, src.ry),
        "outline draws the ELEMENT's conic, not a rescaled one",
    );
    // An outline is a hairline preview, so it must NOT carry the element's own
    // paint -- that is what makes it an outline rather than a thin copy.
    assert!(!cmds.iter().any(|c| matches!(c, Command::FillEllipseArc { .. })),
            "an outlined ellipse is not filled: {cmds:?}");
}
