//! Arrowhead shape definitions and rendering.
//!
//! Each shape is defined as a normalized path in a unit coordinate system:
//! - Pointing right (+x direction)
//! - Tip at origin (0, 0) for tip-at-end alignment
//! - Unit size (1.0 = stroke width at 100% scale)
//!
//! At render time the shape is transformed: translate to endpoint,
//! rotate to match path tangent, scale by stroke_width * scale%.

use web_sys::CanvasRenderingContext2d;
use crate::geometry::element::PathCommand::{self, *};

/// Whether the shape should be filled, stroked (outline), or both.
#[derive(Clone, Copy)]
enum ShapeStyle {
    Filled,
    Outline,
}

/// A static arrowhead shape definition.
struct ArrowShape {
    cmds: &'static [PathCommand],
    style: ShapeStyle,
    /// How far back from the tip the shape extends (in unit coords).
    /// The path is shortened by this × scale so the stroke ends at the base.
    back: f64,
}

// ---------------------------------------------------------------------------
// Shape definitions — all in unit coordinates, tip at (0,0), pointing right.
// Scale factor of ~4.0 relative to stroke width gives good default size.
// ---------------------------------------------------------------------------

const SIMPLE_ARROW: &[PathCommand] = &[
    MoveTo { x: 0.0, y: 0.0 },
    LineTo { x: -4.0, y: -2.0 },
    LineTo { x: -4.0, y: 2.0 },
    ClosePath,
];

const OPEN_ARROW: &[PathCommand] = &[
    MoveTo { x: -4.0, y: -2.0 },
    LineTo { x: 0.0, y: 0.0 },
    LineTo { x: -4.0, y: 2.0 },
];

const CLOSED_ARROW: &[PathCommand] = &[
    // Filled triangle
    MoveTo { x: 0.0, y: 0.0 },
    LineTo { x: -4.0, y: -2.0 },
    LineTo { x: -4.0, y: 2.0 },
    ClosePath,
    // Bar at base
    MoveTo { x: -4.5, y: -2.0 },
    LineTo { x: -4.5, y: 2.0 },
];

const STEALTH_ARROW: &[PathCommand] = &[
    MoveTo { x: 0.0, y: 0.0 },
    LineTo { x: -4.5, y: -1.8 },
    LineTo { x: -3.0, y: 0.0 },
    LineTo { x: -4.5, y: 1.8 },
    ClosePath,
];

const BARBED_ARROW: &[PathCommand] = &[
    MoveTo { x: 0.0, y: 0.0 },
    CurveTo { x1: -2.0, y1: -0.5, x2: -3.5, y2: -1.5, x: -4.5, y: -2.0 },
    LineTo { x: -3.0, y: 0.0 },
    LineTo { x: -4.5, y: 2.0 },
    CurveTo { x1: -3.5, y1: 1.5, x2: -2.0, y2: 0.5, x: 0.0, y: 0.0 },
    ClosePath,
];

const HALF_ARROW_UPPER: &[PathCommand] = &[
    MoveTo { x: 0.0, y: 0.0 },
    LineTo { x: -4.0, y: -2.0 },
    LineTo { x: -4.0, y: 0.0 },
    ClosePath,
];

const HALF_ARROW_LOWER: &[PathCommand] = &[
    MoveTo { x: 0.0, y: 0.0 },
    LineTo { x: -4.0, y: 0.0 },
    LineTo { x: -4.0, y: 2.0 },
    ClosePath,
];

// Circle: center at (-r, 0), radius r. Approximated with 4 cubic bezier arcs.
const CIRCLE_R: f64 = 2.0;
const K: f64 = 0.5522847498; // bezier circle constant (4/3 * (sqrt(2)-1))
const CIRCLE: &[PathCommand] = &[
    MoveTo { x: 0.0, y: 0.0 },
    CurveTo { x1: 0.0, y1: -CIRCLE_R * K, x2: -CIRCLE_R + CIRCLE_R * K, y2: -CIRCLE_R, x: -CIRCLE_R, y: -CIRCLE_R },
    CurveTo { x1: -CIRCLE_R - CIRCLE_R * K, y1: -CIRCLE_R, x2: -2.0 * CIRCLE_R, y2: -CIRCLE_R * K, x: -2.0 * CIRCLE_R, y: 0.0 },
    CurveTo { x1: -2.0 * CIRCLE_R, y1: CIRCLE_R * K, x2: -CIRCLE_R - CIRCLE_R * K, y2: CIRCLE_R, x: -CIRCLE_R, y: CIRCLE_R },
    CurveTo { x1: -CIRCLE_R + CIRCLE_R * K, y1: CIRCLE_R, x2: 0.0, y2: CIRCLE_R * K, x: 0.0, y: 0.0 },
    ClosePath,
];

const SQUARE_SHAPE: &[PathCommand] = &[
    MoveTo { x: 0.0, y: -2.0 },
    LineTo { x: -4.0, y: -2.0 },
    LineTo { x: -4.0, y: 2.0 },
    LineTo { x: 0.0, y: 2.0 },
    ClosePath,
];

const DIAMOND: &[PathCommand] = &[
    MoveTo { x: 0.0, y: 0.0 },
    LineTo { x: -2.5, y: -2.0 },
    LineTo { x: -5.0, y: 0.0 },
    LineTo { x: -2.5, y: 2.0 },
    ClosePath,
];

const SLASH: &[PathCommand] = &[
    MoveTo { x: 0.5, y: -2.0 },
    LineTo { x: -0.5, y: 2.0 },
];

fn get_shape(name: &str) -> Option<ArrowShape> {
    match name {
        "none" | "" => None,
        "simple_arrow"      => Some(ArrowShape { cmds: SIMPLE_ARROW, style: ShapeStyle::Filled, back: 4.0 }),
        "open_arrow"        => Some(ArrowShape { cmds: OPEN_ARROW, style: ShapeStyle::Outline, back: 4.0 }),
        "closed_arrow"      => Some(ArrowShape { cmds: CLOSED_ARROW, style: ShapeStyle::Filled, back: 4.0 }),
        "stealth_arrow"     => Some(ArrowShape { cmds: STEALTH_ARROW, style: ShapeStyle::Filled, back: 3.0 }),
        "barbed_arrow"      => Some(ArrowShape { cmds: BARBED_ARROW, style: ShapeStyle::Filled, back: 3.0 }),
        "half_arrow_upper"  => Some(ArrowShape { cmds: HALF_ARROW_UPPER, style: ShapeStyle::Filled, back: 4.0 }),
        "half_arrow_lower"  => Some(ArrowShape { cmds: HALF_ARROW_LOWER, style: ShapeStyle::Filled, back: 4.0 }),
        "circle"            => Some(ArrowShape { cmds: CIRCLE, style: ShapeStyle::Filled, back: 2.0 * CIRCLE_R }),
        "open_circle"       => Some(ArrowShape { cmds: CIRCLE, style: ShapeStyle::Outline, back: 2.0 * CIRCLE_R }),
        "square"            => Some(ArrowShape { cmds: SQUARE_SHAPE, style: ShapeStyle::Filled, back: 4.0 }),
        "open_square"       => Some(ArrowShape { cmds: SQUARE_SHAPE, style: ShapeStyle::Outline, back: 4.0 }),
        "diamond"           => Some(ArrowShape { cmds: DIAMOND, style: ShapeStyle::Filled, back: 2.5 }),
        "open_diamond"      => Some(ArrowShape { cmds: DIAMOND, style: ShapeStyle::Outline, back: 2.5 }),
        "slash"             => Some(ArrowShape { cmds: SLASH, style: ShapeStyle::Outline, back: 0.5 }),
        _ => None,
    }
}

/// Get the path shortening distance for an arrowhead (in canvas pixels).
/// Returns 0.0 if no arrowhead.
pub fn arrow_setback(name: &str, stroke_width: f64, scale_pct: f64) -> f64 {
    if let Some(shape) = get_shape(name) {
        shape.back * stroke_width * scale_pct / 100.0
    } else {
        0.0
    }
}

/// Shorten a path by moving the first and last points inward along
/// their tangent directions. Returns a new Vec of commands.
pub fn shorten_path(cmds: &[PathCommand], start_setback: f64, end_setback: f64) -> Vec<PathCommand> {
    if cmds.is_empty() { return cmds.to_vec(); }
    let mut result = cmds.to_vec();

    // Shorten start: find the first MoveTo, then the next drawing command,
    // and move the MoveTo point inward along the tangent.
    if start_setback > 0.0 {
        let (sx, sy, angle) = start_tangent(cmds);
        // Tangent points outward from the path (away from the path interior).
        // We want to move the start point ALONG the path (inward), which is
        // opposite to the start tangent direction.
        let dx = -(angle.cos()) * start_setback;
        let dy = -(angle.sin()) * start_setback;
        for cmd in result.iter_mut() {
            if let MoveTo { x, y } = cmd {
                if (*x - sx).abs() < 1e-6 && (*y - sy).abs() < 1e-6 {
                    *x += dx;
                    *y += dy;
                    break;
                }
            }
        }
    }

    // Shorten end: find the last point and move it inward.
    if end_setback > 0.0 {
        let (ex, ey, angle) = end_tangent(cmds);
        // End tangent points along the path direction at the end.
        // Move the endpoint backward (opposite to tangent).
        let dx = -(angle.cos()) * end_setback;
        let dy = -(angle.sin()) * end_setback;
        // Walk backward to find the last command with coordinates
        for cmd in result.iter_mut().rev() {
            match cmd {
                LineTo { x, y } if (*x - ex).abs() < 1e-6 && (*y - ey).abs() < 1e-6 => {
                    *x += dx; *y += dy; break;
                }
                CurveTo { x, y, .. } if (*x - ex).abs() < 1e-6 && (*y - ey).abs() < 1e-6 => {
                    *x += dx; *y += dy; break;
                }
                QuadTo { x, y, .. } if (*x - ex).abs() < 1e-6 && (*y - ey).abs() < 1e-6 => {
                    *x += dx; *y += dy; break;
                }
                MoveTo { x, y } if (*x - ex).abs() < 1e-6 && (*y - ey).abs() < 1e-6 => {
                    *x += dx; *y += dy; break;
                }
                _ => {}
            }
        }
    }

    result
}

/// Compute the tangent angle (in radians) at the start of a path.
/// Returns the angle of the direction vector from the first point outward
/// (pointing away from the path, so the arrowhead faces "into" the path).
/// Handles degenerate cases by walking forward to find a non-coincident point.
pub fn start_tangent(cmds: &[PathCommand]) -> (f64, f64, f64) {
    // Collect all significant points in order.
    let mut points: Vec<(f64, f64)> = Vec::new();
    for cmd in cmds {
        match cmd {
            MoveTo { x, y } => { points.push((*x, *y)); }
            LineTo { x, y } => { points.push((*x, *y)); }
            CurveTo { x1, y1, x2, y2, x, y } => {
                points.push((*x1, *y1));
                points.push((*x2, *y2));
                points.push((*x, *y));
            }
            QuadTo { x1, y1, x, y } => {
                points.push((*x1, *y1));
                points.push((*x, *y));
            }
            SmoothCurveTo { x2, y2, x, y } => {
                points.push((*x2, *y2));
                points.push((*x, *y));
            }
            SmoothQuadTo { x, y } | ArcTo { x, y, .. } => {
                points.push((*x, *y));
            }
            ClosePath => {}
        }
    }
    if points.is_empty() {
        return (0.0, 0.0, 0.0);
    }
    let (sx, sy) = points[0];
    // Walk forward to find a point that's not coincident with the start
    let threshold = 0.1;
    for &(nx, ny) in points.iter().skip(1) {
        let dx = sx - nx;
        let dy = sy - ny;
        if dx * dx + dy * dy > threshold * threshold {
            return (sx, sy, dy.atan2(dx));
        }
    }
    // Fallback
    (sx, sy, std::f64::consts::PI)
}

/// Compute the tangent angle (in radians) at the end of a path.
/// Returns the angle of the direction vector from the last point outward.
/// Handles degenerate cases where control points are coincident with
/// the endpoint (common in pencil-drawn paths) by falling back to
/// earlier control points.
pub fn end_tangent(cmds: &[PathCommand]) -> (f64, f64, f64) {
    // Collect all significant points in order. For each command, record
    // the points that define the tangent direction.
    let mut points: Vec<(f64, f64)> = Vec::new();
    for cmd in cmds {
        match cmd {
            MoveTo { x, y } => { points.push((*x, *y)); }
            LineTo { x, y } => { points.push((*x, *y)); }
            CurveTo { x1, y1, x2, y2, x, y } => {
                points.push((*x1, *y1));
                points.push((*x2, *y2));
                points.push((*x, *y));
            }
            QuadTo { x1, y1, x, y } => {
                points.push((*x1, *y1));
                points.push((*x, *y));
            }
            SmoothCurveTo { x2, y2, x, y } => {
                points.push((*x2, *y2));
                points.push((*x, *y));
            }
            SmoothQuadTo { x, y } | ArcTo { x, y, .. } => {
                points.push((*x, *y));
            }
            ClosePath => {}
        }
    }
    if points.is_empty() {
        return (0.0, 0.0, 0.0);
    }
    let (ex, ey) = *points.last().unwrap();
    // Walk backward to find a point that's not coincident with the endpoint
    let threshold = 0.1;
    for &(px, py) in points.iter().rev().skip(1) {
        let dx = ex - px;
        let dy = ey - py;
        if dx * dx + dy * dy > threshold * threshold {
            return (ex, ey, dy.atan2(dx));
        }
    }
    // Fallback: all points coincident
    (ex, ey, 0.0)
}

/// Draw arrowheads for a path element.
/// `stroke_color` is used for outline shapes; filled shapes use the stroke color as fill.
pub fn draw_arrowheads(
    ctx: &CanvasRenderingContext2d,
    cmds: &[PathCommand],
    start_name: &str,
    end_name: &str,
    start_scale: f64,
    end_scale: f64,
    stroke_width: f64,
    stroke_color: &str,
    center_at_end: bool,
) {
    if let Some(shape) = get_shape(start_name) {
        let (x, y, angle) = start_tangent(cmds);
        let s = stroke_width * start_scale / 100.0;
        draw_one(ctx, &shape, x, y, angle, s, stroke_color, center_at_end);
    }
    if let Some(shape) = get_shape(end_name) {
        let (x, y, angle) = end_tangent(cmds);
        let s = stroke_width * end_scale / 100.0;
        draw_one(ctx, &shape, x, y, angle, s, stroke_color, center_at_end);
    }
}

/// Draw a line's arrowheads (start at (x1,y1), end at (x2,y2)).
pub fn draw_arrowheads_line(
    ctx: &CanvasRenderingContext2d,
    x1: f64, y1: f64, x2: f64, y2: f64,
    start_name: &str,
    end_name: &str,
    start_scale: f64,
    end_scale: f64,
    stroke_width: f64,
    stroke_color: &str,
    center_at_end: bool,
) {
    let dx = x2 - x1;
    let dy = y2 - y1;
    let end_angle = dy.atan2(dx);
    let start_angle = (y1 - y2).atan2(x1 - x2);
    if let Some(shape) = get_shape(start_name) {
        let s = stroke_width * start_scale / 100.0;
        draw_one(ctx, &shape, x1, y1, start_angle, s, stroke_color, center_at_end);
    }
    if let Some(shape) = get_shape(end_name) {
        let s = stroke_width * end_scale / 100.0;
        draw_one(ctx, &shape, x2, y2, end_angle, s, stroke_color, center_at_end);
    }
}

fn draw_one(
    ctx: &CanvasRenderingContext2d,
    shape: &ArrowShape,
    x: f64, y: f64,
    angle: f64,
    scale: f64,
    stroke_color: &str,
    center_at_end: bool,
) {
    if scale <= 0.0 { return; }
    ctx.save();
    ctx.translate(x, y).ok();
    ctx.rotate(angle).ok();
    if center_at_end {
        // Shift so the center of the shape (not the tip) is at the endpoint.
        // Approximate center offset as half the shape extent in -x direction.
        ctx.translate(-2.0 * scale, 0.0).ok();
    }
    ctx.scale(scale, scale).ok();
    ctx.begin_path();
    super::render::build_path(ctx, shape.cmds);
    match shape.style {
        ShapeStyle::Filled => {
            ctx.set_fill_style_str(stroke_color);
            ctx.fill();
        }
        ShapeStyle::Outline => {
            // Fill with white first to mask the stroke line underneath
            ctx.set_fill_style_str("#ffffff");
            ctx.fill();
            ctx.set_stroke_style_str(stroke_color);
            ctx.set_line_width(1.0 / scale); // 1px regardless of scale
            ctx.stroke();
        }
    }
    ctx.restore();
}
