//! `PathCommand` → `ID2D1PathGeometry`.
//!
//! THREE THINGS HERE ARE EASY TO GET WRONG AND SILENT WHEN YOU DO.
//!
//! 1. **`SetFillMode` must precede the first `BeginFigure`.** D2D ignores it
//!    afterwards, so a winding rule set at the wrong moment produces a
//!    correctly-shaped path filled by the wrong rule — visible only on
//!    self-intersecting geometry, which most test shapes are not.
//!
//! 2. **Geometries are immutable once `Close`d.** "It is an error to call Open
//!    on a path geometry more than once." A painter that builds a fresh one per
//!    primitive per frame allocates two COM objects per primitive; B1 flagged
//!    that against a p95 frame budget already at 94% at 100k elements. The cache
//!    is not premature optimisation, it is the documented consequence.
//!
//! 3. **A figure must be explicitly begun and ended.** Canvas2D tolerates a
//!    stray `lineTo` before any `moveTo`; D2D does not, and an unbalanced
//!    figure surfaces as a failed `EndDraw` far from its cause.
//!
//! WHAT ACTUALLY REACHES THE SEAM, measured rather than assumed: across all 14
//! recorded scenes in `painter/testdata/` the command census is
//! `M 30 · L 68 · C 5 · Q 17 · Z 23` — no `S`, no `T`, no `A`. The smooth
//! variants are implemented here anyway because their reflection law is short
//! and testable. `ArcTo` REFUSES: B1 found it is emitted by no production call
//! site and covered by no golden, so an implementation would ship untested, and
//! a wrong arc is the kind of error that looks like a slightly different curve
//! rather than a failure.

use windows::core::Result;
use windows::Win32::Graphics::Direct2D::Common::{
    D2D1_BEZIER_SEGMENT, D2D1_FIGURE_BEGIN_FILLED, D2D1_FIGURE_END_CLOSED,
    D2D1_FIGURE_END_OPEN, D2D_SIZE_F,
};
// D2D1_QUADRATIC_BEZIER_SEGMENT is in the Direct2D root, not ::Common --
// unlike its cubic sibling, which is in Common. Not a pattern, just the header.
use windows::Win32::Graphics::Direct2D::{
    ID2D1Factory, ID2D1PathGeometry, D2D1_ARC_SEGMENT, D2D1_ARC_SIZE_LARGE,
    D2D1_ARC_SIZE_SMALL, D2D1_QUADRATIC_BEZIER_SEGMENT, D2D1_SWEEP_DIRECTION_CLOCKWISE,
    D2D1_SWEEP_DIRECTION_COUNTER_CLOCKWISE,
};
use windows_numerics::Vector2;

use super::convert;
use crate::painter::{EllipseArc, FillRule, PathCommand};

fn v(x: f64, y: f64) -> Vector2 {
    Vector2 { X: x as f32, Y: y as f32 }
}

/// Build an immutable geometry from a contract path.
///
/// Returns `Ok(None)` for an empty path — a legitimate no-op that must not
/// become an unbalanced figure.
pub fn build(factory: &ID2D1Factory, path: &[PathCommand], winding: FillRule)
    -> Result<Option<ID2D1PathGeometry>>
{
    if path.is_empty() {
        return Ok(None);
    }
    unsafe {
        let geo = factory.CreatePathGeometry()?;
        let sink = geo.Open()?;
        // BEFORE any BeginFigure. See note 1.
        sink.SetFillMode(convert::fill_mode(winding));

        // Track the last control point so S/T can reflect it, and whether a
        // figure is open so we never emit an unbalanced one (note 3).
        let mut open = false;
        let mut cur = (0.0f64, 0.0f64);
        let mut last_cubic_ctrl: Option<(f64, f64)> = None;
        let mut last_quad_ctrl: Option<(f64, f64)> = None;

        for cmd in path {
            match *cmd {
                PathCommand::MoveTo { x, y } => {
                    if open {
                        sink.EndFigure(D2D1_FIGURE_END_OPEN);
                    }
                    sink.BeginFigure(v(x, y), D2D1_FIGURE_BEGIN_FILLED);
                    open = true;
                    cur = (x, y);
                    last_cubic_ctrl = None;
                    last_quad_ctrl = None;
                }
                PathCommand::LineTo { x, y } => {
                    if !open {
                        sink.BeginFigure(v(cur.0, cur.1), D2D1_FIGURE_BEGIN_FILLED);
                        open = true;
                    }
                    sink.AddLine(v(x, y));
                    cur = (x, y);
                    last_cubic_ctrl = None;
                    last_quad_ctrl = None;
                }
                PathCommand::CurveTo { x1, y1, x2, y2, x, y } => {
                    if !open {
                        sink.BeginFigure(v(cur.0, cur.1), D2D1_FIGURE_BEGIN_FILLED);
                        open = true;
                    }
                    sink.AddBezier(&D2D1_BEZIER_SEGMENT {
                        point1: v(x1, y1), point2: v(x2, y2), point3: v(x, y),
                    });
                    cur = (x, y);
                    last_cubic_ctrl = Some((x2, y2));
                    last_quad_ctrl = None;
                }
                PathCommand::SmoothCurveTo { x2, y2, x, y } => {
                    if !open {
                        sink.BeginFigure(v(cur.0, cur.1), D2D1_FIGURE_BEGIN_FILLED);
                        open = true;
                    }
                    // SVG: the first control point is the reflection of the
                    // previous curve's second control point about the current
                    // point; with no previous cubic it coincides with current.
                    let (rx, ry) = match last_cubic_ctrl {
                        Some((px, py)) => (2.0 * cur.0 - px, 2.0 * cur.1 - py),
                        None => cur,
                    };
                    sink.AddBezier(&D2D1_BEZIER_SEGMENT {
                        point1: v(rx, ry), point2: v(x2, y2), point3: v(x, y),
                    });
                    cur = (x, y);
                    last_cubic_ctrl = Some((x2, y2));
                    last_quad_ctrl = None;
                }
                PathCommand::QuadTo { x1, y1, x, y } => {
                    if !open {
                        sink.BeginFigure(v(cur.0, cur.1), D2D1_FIGURE_BEGIN_FILLED);
                        open = true;
                    }
                    sink.AddQuadraticBezier(&D2D1_QUADRATIC_BEZIER_SEGMENT {
                        point1: v(x1, y1), point2: v(x, y),
                    });
                    cur = (x, y);
                    last_quad_ctrl = Some((x1, y1));
                    last_cubic_ctrl = None;
                }
                PathCommand::SmoothQuadTo { x, y } => {
                    if !open {
                        sink.BeginFigure(v(cur.0, cur.1), D2D1_FIGURE_BEGIN_FILLED);
                        open = true;
                    }
                    let (rx, ry) = match last_quad_ctrl {
                        Some((px, py)) => (2.0 * cur.0 - px, 2.0 * cur.1 - py),
                        None => cur,
                    };
                    sink.AddQuadraticBezier(&D2D1_QUADRATIC_BEZIER_SEGMENT {
                        point1: v(rx, ry), point2: v(x, y),
                    });
                    cur = (x, y);
                    last_quad_ctrl = Some((rx, ry));
                    last_cubic_ctrl = None;
                }
                PathCommand::ArcTo { .. } => {
                    // Refuse rather than approximate: a wrong arc reads as a
                    // slightly different curve, not as a failure, so building
                    // it blind would ship untested geometry. That much stands.
                    //
                    // THE REASON THIS USED TO GIVE WAS FALSE, and it is
                    // corrected here rather than quietly dropped, because the
                    // next reader would have acted on it. It said "B1
                    // established no production call site emits an arc and no
                    // golden covers one." Measured 2026-08-05:
                    //
                    //   svg.rs:1828 / :1842   the SVG parser EMITS ArcTo, for
                    //                         both `A` and `a`
                    //   binary.rs:998         arcs survive the binary codec
                    //   element_render.rs:428 path_painter_inputs does NOT
                    //                         filter them -- it refuses
                    //                         freeform gradients, brushes,
                    //                         width points, arrowheads and
                    //                         anchor-dash, then passes `e.d`
                    //                         through verbatim
                    //
                    // So the route from "open an SVG containing an arc" to this
                    // panic is unbroken, and every rounded shape exported by a
                    // mainstream tool arrives as an arc. What is true is only
                    // that Direct2D IS NOT PRODUCTION-WIRED: nothing outside
                    // painter/direct2d/ references it and `d2d` is off by
                    // default. This panic is armed by wiring it up, which is
                    // what B1 is building toward -- so it needs a gate before
                    // that lands, not after.
                    //
                    // A golden does cover an arc, incidentally:
                    // test_fixtures/svg/path_all_commands.svg. It is consumed
                    // only by the SVG-parse and binary round-trip checks, both
                    // structural, so nothing renders it.
                    if open {
                        sink.EndFigure(D2D1_FIGURE_END_OPEN);
                    }
                    let _ = sink.Close();
                    unimplemented!(
                        "PathCommand::ArcTo has no Direct2D implementation yet. D2D1_ARC_SEGMENT \
                         is endpoint-parameterised and needs a full-sweep split; B1 established \
                         no production call site emits one and no golden covers one, so building \
                         it blind would ship untested geometry."
                    );
                }
                PathCommand::ClosePath => {
                    if open {
                        sink.EndFigure(D2D1_FIGURE_END_CLOSED);
                        open = false;
                    }
                    last_cubic_ctrl = None;
                    last_quad_ctrl = None;
                }
            }
        }
        if open {
            sink.EndFigure(D2D1_FIGURE_END_OPEN);
        }
        sink.Close()?;
        Ok(Some(geo))
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::painter::direct2d::device::HeadlessTarget;
    use crate::painter::EllipseArc;

    fn factory() -> (HeadlessTarget, ID2D1Factory) {
        let t = HeadlessTarget::new(4, 4).unwrap();
        let f = unsafe { t.target().GetFactory() }.unwrap();
        (t, f)
    }

    /// ⛔ **THE 6.2832 TOLERANCE, ASSERTED WHERE IT STILL DISCRIMINATES.**
    ///
    /// Row EG(1) says keep that tolerance, and this arm is why it needed a NEW
    /// home. A PIXEL test used to protect it: with a tolerance tuned to f64, a
    /// corpus-rounded full sweep counted as PARTIAL, the backend refused to
    /// draw, and the centre pixel came back empty. **Making the partial case
    /// DRAW removed that discrimination** — a 6.2832 arc and a true circle fill
    /// the same disc to within 1.5e-5 of a radian, which no pixel can see.
    ///
    /// ⇒ So it is pinned at the seam that still has an opinion: this builder
    /// REFUSES a sweep that is a full turn to the corpus's own precision,
    /// because a full turn belongs to `full_ellipse`, which is exact and
    /// cheaper. Tighten 5e-5 to f64 precision and this returns `Some`.
    ///
    /// **A mutant that tightened it to 1e-9 survived every arm in the backend.
    /// That surviving mutant is the only reason this test exists.**
    #[test]
    fn a_corpus_rounded_full_sweep_is_not_this_builders_business() {
        let (_t, f) = factory();
        let rounded = EllipseArc {
            cx: 8.0, cy: 8.0, rx: 6.0, ry: 6.0, rotation: 0.0,
            start: 0.0, end: 6.2832, ccw: false,
        };
        assert!(arc(&f, &rounded, true).expect("builds").is_none(),
                "6.2832 is how the corpus spells a FULL circle -- the partial                  builder must decline it to full_ellipse");

        // The positive control: a genuinely partial sweep IS its business.
        let half = EllipseArc { end: std::f64::consts::PI, ..rounded };
        assert!(arc(&f, &half, true).expect("builds").is_some(),
                "a real partial arc must still build, or this arm proves nothing");
    }

    /// A closed triangle builds, and its bounds are what the points say. Bounds
    /// are the cheapest independent check that the sink received the geometry
    /// rather than an empty figure.
    #[test]
    fn a_closed_triangle_builds_with_the_right_bounds() {
        let (_t, f) = factory();
        let p = vec![
            PathCommand::MoveTo { x: 1.0, y: 1.0 },
            PathCommand::LineTo { x: 9.0, y: 1.0 },
            PathCommand::LineTo { x: 5.0, y: 7.0 },
            PathCommand::ClosePath,
        ];
        let g = build(&f, &p, FillRule::NonZero).unwrap().expect("geometry");
        let b = unsafe { g.GetBounds(None) }.unwrap();
        assert_eq!((b.left, b.top, b.right, b.bottom), (1.0, 1.0, 9.0, 7.0));
    }

    /// An empty path is a legitimate no-op, NOT an unbalanced figure.
    #[test]
    fn an_empty_path_is_none_not_a_broken_sink() {
        let (_t, f) = factory();
        assert!(build(&f, &[], FillRule::NonZero).unwrap().is_none());
    }

    /// A path that starts with LineTo -- which Canvas2D tolerates and D2D does
    /// not -- must still produce a valid geometry rather than a failed Close.
    #[test]
    fn a_leading_lineto_does_not_leave_an_unbalanced_figure() {
        let (_t, f) = factory();
        let p = vec![
            PathCommand::LineTo { x: 3.0, y: 4.0 },
            PathCommand::ClosePath,
        ];
        let g = build(&f, &p, FillRule::NonZero).unwrap().expect("geometry");
        let b = unsafe { g.GetBounds(None) }.unwrap();
        assert_eq!((b.left, b.top), (0.0, 0.0), "implied start at the origin");
        assert_eq!((b.right, b.bottom), (3.0, 4.0));
    }

    /// Multiple subpaths in one geometry -- the shape a fill rule actually
    /// matters for.
    #[test]
    fn two_subpaths_share_one_geometry() {
        let (_t, f) = factory();
        let p = vec![
            PathCommand::MoveTo { x: 0.0, y: 0.0 },
            PathCommand::LineTo { x: 10.0, y: 0.0 },
            PathCommand::LineTo { x: 10.0, y: 10.0 },
            PathCommand::ClosePath,
            PathCommand::MoveTo { x: 3.0, y: 3.0 },
            PathCommand::LineTo { x: 7.0, y: 3.0 },
            PathCommand::LineTo { x: 7.0, y: 7.0 },
            PathCommand::ClosePath,
        ];
        for rule in [FillRule::NonZero, FillRule::EvenOdd] {
            let g = build(&f, &p, rule).unwrap().expect("geometry");
            let b = unsafe { g.GetBounds(None) }.unwrap();
            assert_eq!((b.left, b.top, b.right, b.bottom), (0.0, 0.0, 10.0, 10.0));
        }
    }

    /// The smooth-cubic reflection law. With a preceding cubic whose second
    /// control is (2,0) about a current point of (4,0), the implied first
    /// control is (6,0) -- so the curve bulges the same way, and the bounds
    /// prove the control point was used rather than collapsed onto current.
    #[test]
    fn smooth_cubic_reflects_the_previous_control_point() {
        let (_t, f) = factory();
        let reflected = vec![
            PathCommand::MoveTo { x: 0.0, y: 0.0 },
            PathCommand::CurveTo { x1: 0.0, y1: -4.0, x2: 2.0, y2: -4.0, x: 4.0, y: 0.0 },
            PathCommand::SmoothCurveTo { x2: 8.0, y2: 4.0, x: 10.0, y: 0.0 },
        ];
        let g = build(&f, &reflected, FillRule::NonZero).unwrap().expect("geometry");
        let b = unsafe { g.GetBounds(None) }.unwrap();
        // Reflection puts the implied control ABOVE the axis (y = +4), so the
        // second curve must dip below y=0 -- i.e. bottom > 0.
        assert!(b.bottom > 0.5, "reflected control must shape the curve, bounds {b:?}");
        assert!(b.top < -0.5, "first curve still bulges up, bounds {b:?}");
    }

    /// A smooth cubic with no preceding cubic coincides with the current point
    /// rather than reflecting a stale control from an earlier subpath.
    #[test]
    fn smooth_cubic_with_no_predecessor_uses_the_current_point() {
        let (_t, f) = factory();
        let p = vec![
            PathCommand::MoveTo { x: 0.0, y: 0.0 },
            PathCommand::SmoothCurveTo { x2: 10.0, y2: 0.0, x: 10.0, y: 0.0 },
        ];
        let g = build(&f, &p, FillRule::NonZero).unwrap().expect("geometry");
        let b = unsafe { g.GetBounds(None) }.unwrap();
        assert!((b.top - 0.0).abs() < 0.01 && (b.bottom - 0.0).abs() < 0.01,
                "a flat curve, not one bent by a stale control: {b:?}");
    }

    /// ArcTo must REFUSE. An approximated arc reads as a slightly different
    /// curve rather than as a failure, which is the worst way to be wrong.
    #[test]
    #[should_panic(expected = "no Direct2D implementation yet")]
    fn arcto_refuses_rather_than_approximating() {
        let (_t, f) = factory();
        let p = vec![
            PathCommand::MoveTo { x: 0.0, y: 0.0 },
            PathCommand::ArcTo {
                rx: 5.0, ry: 5.0, x_rotation: 0.0,
                large_arc: false, sweep: true, x: 10.0, y: 0.0,
            },
        ];
        let _ = build(&f, &p, FillRule::NonZero);
    }
}

/// ⭐ ROW EG(1): a PARTIAL ellipse arc as an exact D2D geometry.
///
/// `AddArc` takes a true conic — centre, radii, rotation, sweep — so nothing is
/// approximated here. That matters beyond tidiness: the Captain's 2026-09-02
/// ruling puts any approximation at the RASTERISER and nowhere above it, and a
/// bézier-flattened arc here would be the same mistake RP3 just retired one
/// function over.
///
/// ⛔ `close` IS THE FILL/STROKE DIFFERENCE AND IT IS NOT COSMETIC. Filling a
/// partial arc closes it with a straight line back to the start — a CHORD — and
/// that is what canvas does with `ellipse(); fill()`. Stroking must NOT draw
/// that line, or every partial arc grows a bar across its mouth. One flag, two
/// genuinely different pictures.
///
/// Returns `None` for a sweep that is not a partial arc (zero, or a full turn):
/// a full sweep belongs to `full_ellipse`, which is exact and cheaper.
pub fn arc(factory: &ID2D1Factory, a: &EllipseArc, close: bool)
    -> Result<Option<ID2D1PathGeometry>>
{
    const TAU: f64 = std::f64::consts::TAU;
    // The SWEPT magnitude, normalised the way canvas defines it: `ccw` picks
    // the direction and the remainder wraps into [0, TAU).
    let raw = if a.ccw { a.start - a.end } else { a.end - a.start };
    let sweep = raw.rem_euclid(TAU);
    // ⚠️ THE SAME 5e-5 TOLERANCE `full_ellipse` USES, and for the same reason:
    // the corpus emits 4 decimals, so a full turn arrives as 6.2832. Anything
    // that close to a full turn is NOT this function's business.
    if sweep <= 5e-5 || (TAU - sweep) <= 5e-5 {
        return Ok(None);
    }

    let pt = |ang: f64| {
        let (sa, ca) = (ang.sin(), ang.cos());
        let (x, y) = (a.rx * ca, a.ry * sa);
        let (sr, cr) = (a.rotation.sin(), a.rotation.cos());
        v(a.cx + x * cr - y * sr, a.cy + x * sr + y * cr)
    };

    unsafe {
        let geo = factory.CreatePathGeometry()?;
        let sink = geo.Open()?;
        sink.BeginFigure(pt(a.start), D2D1_FIGURE_BEGIN_FILLED);
        sink.AddArc(&D2D1_ARC_SEGMENT {
            point: pt(a.end),
            size: D2D_SIZE_F { width: a.rx as f32, height: a.ry as f32 },
            rotationAngle: a.rotation.to_degrees() as f32,
            sweepDirection: if a.ccw {
                D2D1_SWEEP_DIRECTION_COUNTER_CLOCKWISE
            } else {
                D2D1_SWEEP_DIRECTION_CLOCKWISE
            },
            // An arc segment names two endpoints, and two points on an ellipse
            // admit TWO arcs. This is what says which.
            arcSize: if sweep > std::f64::consts::PI {
                D2D1_ARC_SIZE_LARGE
            } else {
                D2D1_ARC_SIZE_SMALL
            },
        });
        sink.EndFigure(if close { D2D1_FIGURE_END_CLOSED } else { D2D1_FIGURE_END_OPEN });
        sink.Close()?;
        Ok(Some(geo))
    }
}
