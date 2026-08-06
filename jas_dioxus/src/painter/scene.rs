//! Scene builders exercised through the [`Painter`](super::Painter) trait.
//! Shared by the proof test (via `RecordingPainter`) and the R10 bench (via
//! `NoOpPainter`) so both drive the SAME lowering code.

use super::{
    Brush, ColorStop, EllipseArc, LinearGradient, Painter, PathCommand, Rect, StrokeStyle, TextRun,
};
use crate::geometry::element::{BlendMode, Color, FillRule, LineCap, LineJoin, Transform};

fn demo_stroke(width: f64) -> StrokeStyle {
    StrokeStyle { width, cap: LineCap::Round, join: LineJoin::Miter, miter: 10.0, dash: vec![] }
}

/// The PROOF scene — a small real slice that exercises the whole vocabulary
/// needed for a representative frame: a filled rect, a circle (ellipse_arc),
/// a stroked bezier path, a solid AND a linear-gradient brush, a push_group
/// with alpha, and one FastRun text op — all in DOCUMENT space under a single
/// view transform pushed as a matrix (D2). If any element could not be
/// expressed, that would be a contract-amendment finding.
pub fn build_proof_scene(p: &mut impl Painter) {
    // D2: the driver owns the view transform and pushes it as ONE matrix. All
    // paint coordinates below stay in document space — the property that makes
    // the R7 float law stable.
    p.push_state(Transform { a: 2.0, b: 0.0, c: 0.0, d: 2.0, e: 12.5, f: 40.0 });

    // 1) A filled rectangle with a solid brush.
    p.fill_rect(
        Rect { x: 10.0, y: 20.0, w: 100.0, h: 60.0 },
        &Brush::Solid(Color::rgb(0.2, 0.4, 0.8)),
        1.0,
    );

    // 2) A circle via the ellipse_arc primitive — filled THEN stroked (today's
    //    Circle element does exactly this; the fill/stroke split is amendment
    //    A2). This is the refuter's missing-circle case.
    let circle = EllipseArc::circle(200.0, 120.0, 40.0);
    p.fill_ellipse_arc(&circle, FillRule::NonZero, &Brush::Solid(Color::rgb(0.9, 0.3, 0.1)), 1.0);
    p.stroke_ellipse_arc(&circle, &Brush::Solid(Color::BLACK), &demo_stroke(2.0), 1.0);

    // 3) A push_group with alpha (non-isolated) wrapping a stroked bezier path
    //    painted with a LINEAR-GRADIENT brush.
    p.push_group(0.5, BlendMode::Normal);
    let bezier = vec![
        PathCommand::MoveTo { x: 20.0, y: 200.0 },
        PathCommand::CurveTo { x1: 60.0, y1: 120.0, x2: 140.0, y2: 280.0, x: 180.0, y: 200.0 },
    ];
    let grad = Brush::Linear(LinearGradient {
        x0: 20.0,
        y0: 200.0,
        x1: 180.0,
        y1: 200.0,
        stops: vec![
            ColorStop { offset: 0.0, color: Color::rgb(1.0, 0.0, 0.0) },
            ColorStop { offset: 1.0, color: Color::Rgb { r: 0.0, g: 0.0, b: 1.0, a: 0.5 } },
        ],
    });
    p.stroke_path(&bezier, &grad, &demo_stroke(4.0), 1.0);
    p.pop_group();

    // 4) One FastRun text op (rides PH1 — interleaves in z-order).
    p.draw_text_run(
        &TextRun::FastRun {
            font: "sans-serif".to_string(),
            size: 16.0,
            text: "Painter spike".to_string(),
            letter_spacing: 0.5,
            x: 24.0,
            y: 300.0,
        },
        &Brush::Solid(Color::BLACK),
        1.0,
    );

    // 5) The vocabulary the scene MISSED until 2026-08-05, added because the
    // coverage gate in painter/tests.rs measured it rather than assuming: a
    // clip, a fill_path, and a stroke_rect were emitted by NO painter test in
    // ANY port. `fill_path` was doubly hidden — it appears in
    // `build_synthetic_scene` below, which has no golden, so a source grep
    // counted it as covered while the recorded output never carried it.
    //
    // The fill_path deliberately contains an ARC. The windows seat measured
    // (2026-08-05) that Rust FLATTENS every `ArcTo` to a line
    // (`painter/canvas2d.rs:130`, and no arc-to-bezier exists in this crate)
    // while Swift draws a real curve via `arcToBeziers` — a live artist-visible
    // divergence, reachable by any rounded shape exported from another tool.
    // A golden pinned WITHOUT an arc would certify a vocabulary real files use
    // and this corpus never sees. It does not catch the divergence — both
    // ports emit an identical display list and differ strictly below it — but
    // it locates the flattening in the consumer and leaves a scene ready for a
    // consumption-level check.
    p.push_state(Transform::IDENTITY);
    p.clip(
        &[
            PathCommand::MoveTo { x: 200.0, y: 200.0 },
            PathCommand::LineTo { x: 320.0, y: 200.0 },
            PathCommand::LineTo { x: 320.0, y: 280.0 },
            PathCommand::ClosePath,
        ],
        FillRule::NonZero,
    );
    p.fill_path(
        &[
            PathCommand::MoveTo { x: 210.0, y: 250.0 },
            PathCommand::ArcTo {
                rx: 40.0,
                ry: 25.0,
                x_rotation: 15.0,
                large_arc: false,
                sweep: true,
                x: 300.0,
                y: 250.0,
            },
            PathCommand::ClosePath,
        ],
        FillRule::EvenOdd,
        &Brush::Solid(Color::rgb(0.9, 0.3, 0.1)),
        0.75,
    );
    p.stroke_rect(
        Rect { x: 210.0, y: 210.0, w: 90.0, h: 30.0 },
        &Brush::Solid(Color::rgb(0.1, 0.6, 0.3)),
        &demo_stroke(2.0),
        1.0,
    );
    p.pop_state();

    p.pop_state();
}

/// A synthetic scene of `n` of each primitive kind — the R10 bench input. Kept
/// simple (the contract's "N of each of the ~6 element kinds"); coordinates
/// vary by index so nothing is constant-folded. Wrapped in a group so
/// push/pop_group are on the hot path too.
pub fn build_synthetic_scene(p: &mut impl Painter, n: usize) {
    p.push_state(Transform { a: 1.5, b: 0.0, c: 0.0, d: 1.5, e: 0.0, f: 0.0 });
    p.push_group(0.9, BlendMode::Multiply);

    let solid = Brush::Solid(Color::rgb(0.3, 0.6, 0.2));
    let grad = Brush::Linear(LinearGradient {
        x0: 0.0,
        y0: 0.0,
        x1: 50.0,
        y1: 50.0,
        stops: vec![
            ColorStop { offset: 0.0, color: Color::WHITE },
            ColorStop { offset: 1.0, color: Color::BLACK },
        ],
    });
    let stroke = demo_stroke(1.5);

    for i in 0..n {
        let f = i as f64;

        // fill_rect
        p.fill_rect(Rect { x: f, y: f * 0.5, w: 20.0, h: 12.0 }, &solid, 1.0);

        // fill_path (a small triangle)
        let tri = vec![
            PathCommand::MoveTo { x: f, y: f },
            PathCommand::LineTo { x: f + 10.0, y: f },
            PathCommand::LineTo { x: f + 5.0, y: f + 10.0 },
            PathCommand::ClosePath,
        ];
        p.fill_path(&tri, FillRule::NonZero, &grad, 0.8);

        // stroke_path (a cubic)
        let curve = vec![
            PathCommand::MoveTo { x: f, y: 100.0 + f },
            PathCommand::CurveTo {
                x1: f + 10.0, y1: 80.0 + f, x2: f + 20.0, y2: 120.0 + f, x: f + 30.0, y: 100.0 + f,
            },
        ];
        p.stroke_path(&curve, &solid, &stroke, 1.0);

        // fill_ellipse_arc (a circle)
        let c = EllipseArc::circle(f * 2.0, f * 2.0, 6.0);
        p.fill_ellipse_arc(&c, FillRule::NonZero, &grad, 1.0);

        // stroke_ellipse_arc
        p.stroke_ellipse_arc(&c, &solid, &stroke, 1.0);

        // draw_text_run (fast run)
        p.draw_text_run(
            &TextRun::FastRun {
                font: "sans-serif".to_string(),
                size: 12.0,
                text: "label".to_string(),
                letter_spacing: 0.0,
                x: f,
                y: 200.0 + f,
            },
            &solid,
            1.0,
        );
    }

    p.pop_group();
    p.pop_state();
}
