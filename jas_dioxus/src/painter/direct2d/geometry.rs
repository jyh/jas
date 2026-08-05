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
    D2D1_FIGURE_END_OPEN,
};
// D2D1_QUADRATIC_BEZIER_SEGMENT is in the Direct2D root, not ::Common --
// unlike its cubic sibling, which is in Common. Not a pattern, just the header.
use windows::Win32::Graphics::Direct2D::{
    ID2D1Factory, ID2D1PathGeometry, D2D1_QUADRATIC_BEZIER_SEGMENT,
};
use windows_numerics::Vector2;

use super::convert;
use crate::painter::{FillRule, PathCommand};

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
                    // Refuse rather than approximate. B1: no production call
                    // site emits an arc and no golden covers one, so any
                    // implementation ships untested -- and a wrong arc reads as
                    // a slightly different curve, not as a failure.
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

    fn factory() -> (HeadlessTarget, ID2D1Factory) {
        let t = HeadlessTarget::new(4, 4).unwrap();
        let f = unsafe { t.target().GetFactory() }.unwrap();
        (t, f)
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
