//! Scene builders exercised through the [`Painter`](super::Painter) trait.
//! Shared by the proof test (via `RecordingPainter`) and the R10 bench (via
//! `NoOpPainter`) so both drive the SAME lowering code.

use super::{Brush, ColorStop, EllipseArc, LinearGradient, Mask, Painter, PathCommand, Rect, StrokeStyle, TextRun};
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

// ---------------------------------------------------------------------------
// AMENDMENT A6 CORPUS (design block §6). Four scenes the block says testdata/
// owes post-ratification. They are DISPLAY-LIST goldens: they pin the op STREAM
// and the bracket grammar, not pixels.
//
// ⛔ THESE ARE AUTHORED FROM THE CONTRACT, NOT CAPTURED FROM HEAD. That is the
// point of writing them now: the PH4 conversion must LEARN to emit these. A
// golden captured from today's renderer would pin defect D-α — the very thing
// A6 ruled a defect — and would then "pass" forever by describing the bug.
// ---------------------------------------------------------------------------

/// ⛔ A NON-NORMAL **GROUP** BLEND — the fixture a DECLARED GAP had been missing.
///
/// `direct2d/replay.rs` declares three gaps, and one of them —
/// *"non-Normal blend needs an effect graph"* — fires ONLY on a `push_group`
/// carrying a non-Normal mode. Measured 2026-08-29: **both `push_group` ops in
/// the whole corpus were `normal`**, and the single non-Normal blend rode
/// `push_isolated_layer`, landing in the isolated-layer gap instead. So that arm
/// never fired, and an arm nothing drives is indistinguishable from one that
/// cannot.
///
/// That is the SAME defect this corpus already repaired once: the A6 goldens
/// landed because B1 had measured ZERO mask ops across 14 scenes, and the replay
/// test's own comment says a stated limit *"is itself a stated limit of this
/// measurement rather than evidence they work."* The mask half was fixed and the
/// group-blend half was left standing in the same breath.
///
/// ⚠️ THIS DOES NOT ACTIVATE GROUP-LEVEL BLEND, and must not be read as doing
/// so. The contract is explicit that a group's blend is inert by construction —
/// leaf primitives inherit the innermost group's mode and a nested `push_group`
/// resets it. This scene pins the OP STREAM: that a non-Normal mode survives
/// recording on a group, so every backend must say what it does about one.
pub fn build_group_blend_scene(p: &mut impl Painter) {
    // A backdrop, so the group op is recorded in context rather than alone.
    p.fill_rect(
        Rect { x: 0.0, y: 0.0, w: 30.0, h: 30.0 },
        &Brush::Solid(Color::rgb(0.2, 0.4, 0.8)),
        1.0,
    );
    p.push_group(1.0, BlendMode::Multiply);
    p.fill_rect(
        Rect { x: 5.0, y: 5.0, w: 20.0, h: 20.0 },
        &Brush::Solid(Color::rgb(0.9, 0.7, 0.1)),
        1.0,
    );
    p.pop_group();
}

/// ⛔ AN ISOLATED LAYER WITH **NO MASK** — the state the corpus could not express.
///
/// Measured 2026-08-29: across the whole corpus `push_isolated_layer` and
/// `push_mask_layer` both totalled 7. **Every isolated layer was paired with a
/// mask**, so no fixture anywhere separated the two capabilities. That blindness
/// is not hypothetical — it hid a state this codebase actually held:
///
///   * `Canvas2dPainter` from #47 until #55: isolated layers EXECUTED, mask ops
///     still `unimplemented!()`. A full day in a state the corpus cannot describe.
///   * and the state `direct2d` will pass through if it implements layers first,
///     which is the natural order — the layer target IS the surface a mask eats
///     into, so it must exist before the law that consumes it.
///
/// A corpus that can only say "the A6 bracket" as one unit forces every consumer
/// to be equally coarse. This scene splits it.
///
/// THE BODY OVERLAPS ITSELF DELIBERATELY. Isolation's whole observable content
/// is that the overlap does NOT compound — the layer's alpha is spent once at
/// the composite, not per primitive. A single-rect body would pin the bracket
/// while saying nothing about what isolation MEANS.
pub fn build_a6_layer_without_mask_scene(p: &mut impl Painter) {
    p.push_isolated_layer(0.6, BlendMode::Normal);
    p.fill_rect(
        Rect { x: 0.0, y: 0.0, w: 20.0, h: 20.0 },
        &Brush::Solid(Color::rgb(0.2, 0.7, 0.4)),
        1.0,
    );
    // Overlapping the first: inside the layer these compound at alpha 1.0, and
    // the layer's 0.6 applies ONCE to the composited result.
    p.fill_rect(
        Rect { x: 10.0, y: 10.0, w: 20.0, h: 20.0 },
        &Brush::Solid(Color::rgb(0.8, 0.2, 0.6)),
        1.0,
    );
    p.pop_isolated_layer();
}

/// §6.1 — one scene per law variant. Kills the mask-shaped half of the vacuity
/// B1 measured: ZERO mask ops across all 14 recorded scenes.
pub fn build_a6_law_variants_scene(p: &mut impl Painter) {
    for (i, mask) in [
        Mask::LuminanceClipIn,
        Mask::AlphaClipOut,
        Mask::AlphaRevealOutsideBbox { bbox: Rect { x: 4.0, y: 4.0, w: 12.0, h: 12.0 } },
    ]
    .into_iter()
    .enumerate()
    {
        let dx = 40.0 * i as f64;
        p.push_isolated_layer(1.0, BlendMode::Normal);
        p.fill_rect(
            Rect { x: dx, y: 0.0, w: 20.0, h: 20.0 },
            &Brush::Solid(Color::rgb(0.2, 0.4, 0.8)),
            1.0,
        );
        // The mask bracket nests INSIDE the layer and wraps the MASK ARTWORK.
        p.push_mask_layer(mask);
        p.fill_rect(
            Rect { x: dx + 4.0, y: 4.0, w: 12.0, h: 12.0 },
            &Brush::Solid(Color::rgb(1.0, 1.0, 1.0)),
            1.0,
        );
        p.pop_mask_layer();
        // Nothing paints between pop_mask_layer and pop_isolated_layer (§3.2).
        p.pop_isolated_layer();
    }
}

/// §6.2 — a masked, HALF-OPACITY element inside a HALF-ALPHA group. This is the
/// D-α pin, and the numbers are the whole point:
///
///   group alpha 0.5  ×  layer alpha 0.5  =  0.25, applied ONCE at the composite.
///
/// HEAD renders this at 0.25 from the ELEMENT ALONE (opacity² via a double
/// apply) and DISCARDS the group's 0.5 by replacing the inherited product
/// instead of multiplying into it. So the two disagree, and this golden is what
/// makes the disagreement visible instead of invisible.
pub fn build_a6_alpha_law_scene(p: &mut impl Painter) {
    p.push_group(0.5, BlendMode::Normal);
    p.push_isolated_layer(0.5, BlendMode::Normal);
    // ⛔ The body paints at paint_alpha 1.0. The element's own opacity rides the
    // LAYER, consumed once at pop_isolated_layer — it must NOT also be
    // multiplied into the body primitives, which is exactly D-α's first half.
    p.fill_rect(
        Rect { x: 0.0, y: 0.0, w: 20.0, h: 20.0 },
        &Brush::Solid(Color::rgb(0.9, 0.3, 0.1)),
        1.0,
    );
    p.push_mask_layer(Mask::LuminanceClipIn);
    p.fill_rect(
        Rect { x: 5.0, y: 5.0, w: 10.0, h: 10.0 },
        &Brush::Solid(Color::WHITE),
        1.0,
    );
    p.pop_mask_layer();
    p.pop_isolated_layer();
    p.pop_group();
}

/// §6.3 — layer-in-layer (mask-in-mask). Pins the stack law of §3.5 against
/// defect D-β, where a STATIC scratch surface self-clobbers at nesting depth ≥ 2:
/// the inner layer's buffer must not be the outer layer's buffer.
pub fn build_a6_nested_layers_scene(p: &mut impl Painter) {
    p.push_isolated_layer(0.8, BlendMode::Normal);
    p.fill_rect(Rect { x: 0.0, y: 0.0, w: 30.0, h: 30.0 }, &Brush::Solid(Color::rgb(0.1, 0.6, 0.3)), 1.0);

    p.push_isolated_layer(0.6, BlendMode::Normal);
    p.fill_rect(Rect { x: 5.0, y: 5.0, w: 20.0, h: 20.0 }, &Brush::Solid(Color::rgb(0.8, 0.8, 0.1)), 1.0);
    p.push_mask_layer(Mask::AlphaClipOut);
    p.fill_rect(Rect { x: 8.0, y: 8.0, w: 6.0, h: 6.0 }, &Brush::Solid(Color::BLACK), 1.0);
    p.pop_mask_layer();
    p.pop_isolated_layer();

    // The OUTER layer's own mask, applied after the inner layer composited in.
    p.push_mask_layer(Mask::LuminanceClipIn);
    p.fill_rect(Rect { x: 2.0, y: 2.0, w: 26.0, h: 26.0 }, &Brush::Solid(Color::WHITE), 1.0);
    p.pop_mask_layer();
    p.pop_isolated_layer();
}

/// §6.4 — a masked element with a NON-NORMAL blend. The first golden anywhere in
/// this repo to see a blend cross the seam operatively: B1 counted one
/// push_group, blend Normal. The blend rides the LAYER and is consumed at the
/// closing composite, where the blit sees the true parent backdrop.
pub fn build_a6_blend_scene(p: &mut impl Painter) {
    p.fill_rect(Rect { x: 0.0, y: 0.0, w: 40.0, h: 40.0 }, &Brush::Solid(Color::rgb(0.2, 0.2, 0.9)), 1.0);
    p.push_isolated_layer(1.0, BlendMode::Multiply);
    p.fill_rect(Rect { x: 10.0, y: 10.0, w: 20.0, h: 20.0 }, &Brush::Solid(Color::rgb(0.9, 0.9, 0.2)), 1.0);
    p.push_mask_layer(Mask::AlphaClipOut);
    p.fill_rect(Rect { x: 14.0, y: 14.0, w: 8.0, h: 8.0 }, &Brush::Solid(Color::BLACK), 1.0);
    p.pop_mask_layer();
    p.pop_isolated_layer();
}
