//! Element → [`Painter`] lowering (PH1 slice) and the R4 display-list gate.
//!
//! This module is the seam between the document model (`geometry::element`) and
//! the [`Painter`](super::Painter) trait. It has two jobs:
//!
//! 1. **The reference renderer** [`emit_element`] — lowers the PH1-expressible
//!    element surface (filled/stroked rects, circles/ellipses fill-then-stroke,
//!    lines, bezier/quad paths, polygons/polylines; solid + linear/radial
//!    gradient brushes; dashed strokes; stroke alignment via build-time clip;
//!    nested groups with non-isolated alpha; a fast-path text run) to `Painter`
//!    calls. The Phase-2 goldens (`tests` below, `testdata/ref_*.json`) lock its
//!    output through a `RecordingPainter`. This is the behavior-lock the
//!    production conversion lands behind. It is a DISPLAY-LIST-EQUIVALENT
//!    (Option-A, contract R4) lowering — not a byte-for-byte transcript of
//!    `render.rs`'s exact `ctx.*` interleaving. It threads the effective alpha
//!    the way `render.rs` does (a folded multiply, D3: the `globalAlpha`
//!    getter dies), so a future PH2 driver can adopt it wholesale.
//!
//! 2. **The capability router** [`element_needs_legacy`] and the byte-identical
//!    leaf-paint helper [`line_painter_inputs`] — the PH3 production slice.
//!    `render.rs` routes an element that needs a PH3/PH4 feature (opacity mask,
//!    type-on-path / placed-glyph text, freeform gradient) to the legacy
//!    raw-`ctx` path unchanged; the one PH1 leaf paint that is proven
//!    byte-identical to `render.rs` today — a plain center-aligned, solid,
//!    arrowless [`Line`](Element::Line) — routes through a
//!    [`Canvas2dPainter`](super::canvas2d::Canvas2dPainter). See
//!    `line_painter_inputs` for the exact equivalence argument.
//!
//! DELIBERATELY EXCLUDED from PH1 (their phases own them): opacity masks (PH4),
//! type-on-path / placed-glyph text (PH3), freeform gradients (a build-time
//! lowering concern the seam never carries — contract A5).

use crate::geometry::element::{
    Color, Element, Fill, FillRule, Gradient, GradientType, LineElem, PathCommand, Stroke,
    StrokeAlign, Visibility,
};

use super::{
    Brush, ColorStop, EllipseArc, LinearGradient, Painter, RadialGradient, Rect, StrokeStyle,
    TextRun,
};

// ---------------------------------------------------------------------------
// Capability router (PH3 production slice)
// ---------------------------------------------------------------------------

/// Does this element need a capability the PH1 `Painter` surface cannot
/// express? Such elements STAY on the legacy raw-`ctx` path in the production
/// conversion (contract R4: convert only what is behavior-preserving).
///
/// PH1 keeps on legacy:
/// - **opacity masks** (an active [`Mask`](crate::geometry::element::Mask)) —
///   PH4 owns the scratch/luminance pipeline;
/// - **freeform gradients** on fill or stroke — a build-time lowering concern
///   the seam never carries (contract A5); today they render unpainted;
/// - **text** ([`Text`](Element::Text)/[`TextPath`](Element::TextPath)) and
///   **live** elements — placed-glyph/type-on-path shaping is PH3 net-new work;
///   the FastRun fast path is proven in the reference renderer but the
///   production `render.rs` text pipeline (tspans, `letterSpacing` via Reflect,
///   per-glyph rotate, baseline shift) is not mechanically 1:1 yet.
pub fn element_needs_legacy(elem: &Element) -> bool {
    // Active opacity mask (PH4).
    if elem
        .common()
        .mask
        .as_ref()
        .map(|m| !m.disabled)
        .unwrap_or(false)
    {
        return true;
    }
    // Freeform gradient on fill or stroke (never crosses the seam).
    if elem
        .fill_gradient()
        .map(|g| g.gtype == GradientType::Freeform)
        .unwrap_or(false)
    {
        return true;
    }
    if elem
        .stroke_gradient()
        .map(|g| g.gtype == GradientType::Freeform)
        .unwrap_or(false)
    {
        return true;
    }
    // Text / type-on-path / live geometry.
    matches!(
        elem,
        Element::Text(_) | Element::TextPath(_) | Element::Live(_)
    )
}

/// The `Painter` inputs for a PH1-convertible [`Line`](Element::Line): its
/// path, a solid brush, the stroke style, and the stroke's own opacity.
#[derive(Debug, Clone, PartialEq)]
pub struct LinePaint {
    pub path: Vec<PathCommand>,
    pub brush: Brush,
    pub stroke: StrokeStyle,
    /// The stroke's paint-time opacity (`Stroke::opacity`, today's `stroke_op`).
    pub stroke_op: f64,
}

/// Return the `Painter` inputs for `e` IFF a plain `Line` stroke is expressible
/// on the PH1 seam **byte-identically** to `render.rs`'s legacy Line body,
/// else `None` (the caller keeps the legacy path). This is the one production
/// leaf-paint the PH1 conversion routes through the `Painter`.
///
/// # Convertible ⟺ every divergence source is absent
///
/// Convertible = a stroke is present, with: a solid color (**no** stroke
/// gradient), **center** alignment (inside/outside add clip ops), **no**
/// arrowheads (setback + arrowhead draws), **no** variable width
/// (`width_points`), and **no** anchor-aligned dashing (the dash-expansion
/// path). `outline` mode is handled by the caller (it takes a different
/// style) and is NOT convertible here.
///
/// # Why the emitted ops are byte-identical to the legacy body
///
/// `render.rs`'s Line body, for exactly this case, issues (after the shared
/// per-element prologue that stays raw `ctx`):
/// `set_stroke_style_str(css) · set_line_width(w) · set_line_cap · set_line_join
/// · set_miter_limit · set_line_dash(dash) · set_global_alpha(base·op) ·
/// begin_path · move_to · line_to · stroke`. A
/// [`Canvas2dPainter`](super::canvas2d::Canvas2dPainter) with an EMPTY group
/// stack, on `stroke_path` (whose body is ordered
/// brush → stroke-style → alpha → path → stroke), emits that identical
/// sequence when the caller passes `paint_alpha = base_alpha * stroke_op`
/// (`apply_alpha` multiplies the empty group product `1.0`). `css_color`,
/// the cap/join strings, and the dash array all match `render.rs` by
/// construction (same helpers / same mapping).
pub fn line_painter_inputs(e: &LineElem) -> Option<LinePaint> {
    let s = e.stroke.as_ref()?;
    // Solid only — a stroke gradient takes the gradient path.
    if e.stroke_gradient.is_some() {
        return None;
    }
    // No variable width, no arrowheads, center alignment only.
    if !e.width_points.is_empty() {
        return None;
    }
    if s.align != StrokeAlign::Center {
        return None;
    }
    if s.start_arrow != crate::geometry::element::Arrowhead::None
        || s.end_arrow != crate::geometry::element::Arrowhead::None
    {
        return None;
    }
    // Anchor-aligned dashing with an active pattern takes the dash-expansion
    // path (and `render.rs` then clears the platform dash); not convertible.
    if s.dash_align_anchors && !s.dash_array().is_empty() {
        return None;
    }
    Some(LinePaint {
        path: vec![
            PathCommand::MoveTo { x: e.x1, y: e.y1 },
            PathCommand::LineTo { x: e.x2, y: e.y2 },
        ],
        brush: Brush::Solid(s.color),
        stroke: stroke_style(s, s.width),
        stroke_op: s.opacity,
    })
}

// ---------------------------------------------------------------------------
// The reference renderer (Phase-2 gate)
// ---------------------------------------------------------------------------

/// Lower one element (and its subtree) to `Painter` calls. `incoming_alpha` is
/// the accumulated ancestor alpha (1.0 at the top); the element's own opacity
/// multiplies into it (non-isolated: the fold IS the compounding). Paint ops
/// carry `paint_alpha = effective_alpha * paint_op` (fill/stroke opacity),
/// mirroring `render.rs`'s `base_alpha * fill_op` / `* stroke_op`.
///
/// Assumes `!element_needs_legacy(elem)`; a legacy-only element paints nothing.
pub fn emit_element(p: &mut dyn Painter, elem: &Element, incoming_alpha: f64) {
    if elem.visibility() == Visibility::Invisible {
        return;
    }
    let eff = incoming_alpha * elem.opacity();
    let pushed = elem.transform().is_some();
    if let Some(t) = elem.transform() {
        p.push_state(*t);
    }

    match elem {
        Element::Group(_) | Element::Layer(_) => {
            if let Some(children) = elem.children() {
                for child in children {
                    if !element_needs_legacy(child) {
                        emit_element(p, child, eff);
                    }
                }
            }
        }
        Element::Line(e) => {
            if let Some(s) = e.stroke.as_ref() {
                let brush = stroke_brush(s, e.stroke_gradient.as_deref(), elem);
                emit_path_stroke(
                    p,
                    &[
                        PathCommand::MoveTo { x: e.x1, y: e.y1 },
                        PathCommand::LineTo { x: e.x2, y: e.y2 },
                    ],
                    &brush,
                    s,
                    eff,
                );
            }
        }
        Element::Rect(e) => {
            let bbox = (e.x, e.y, e.width, e.height);
            if e.rx > 0.0 || e.ry > 0.0 {
                let path = rounded_rect_path(e.x, e.y, e.width, e.height, e.rx, e.ry);
                emit_fill_path(p, &path, FillRule::NonZero, e.fill.as_ref(), e.fill_gradient.as_deref(), bbox, eff);
                if let Some(s) = e.stroke.as_ref() {
                    let brush = stroke_brush(s, e.stroke_gradient.as_deref(), elem);
                    emit_path_stroke(p, &path, &brush, s, eff);
                }
            } else {
                let rect = Rect { x: e.x, y: e.y, w: e.width, h: e.height };
                if let Some((brush, op)) = fill_paint(e.fill.as_ref(), e.fill_gradient.as_deref(), bbox) {
                    p.fill_rect(rect, &brush, eff * op);
                }
                if let Some(s) = e.stroke.as_ref() {
                    // Center alignment lowers to stroke_rect; inside/outside
                    // would need the shape as a path for the clip lowering, so
                    // route those through the path form.
                    let brush = stroke_brush(s, e.stroke_gradient.as_deref(), elem);
                    if s.align == StrokeAlign::Center {
                        p.stroke_rect(rect, &brush, &stroke_style(s, s.width), eff * s.opacity);
                    } else {
                        let path = rounded_rect_path(e.x, e.y, e.width, e.height, 0.0, 0.0);
                        emit_path_stroke(p, &path, &brush, s, eff);
                    }
                }
            }
        }
        Element::Circle(e) => {
            let bbox = (e.cx - e.r, e.cy - e.r, e.r * 2.0, e.r * 2.0);
            let arc = EllipseArc::circle(e.cx, e.cy, e.r);
            if let Some((brush, op)) = fill_paint(e.fill.as_ref(), e.fill_gradient.as_deref(), bbox) {
                p.fill_ellipse_arc(&arc, FillRule::NonZero, &brush, eff * op);
            }
            if let Some(s) = e.stroke.as_ref() {
                let brush = stroke_brush(s, e.stroke_gradient.as_deref(), elem);
                p.stroke_ellipse_arc(&arc, &brush, &stroke_style(s, s.width), eff * s.opacity);
            }
        }
        Element::Ellipse(e) => {
            let bbox = (e.cx - e.rx, e.cy - e.ry, e.rx * 2.0, e.ry * 2.0);
            let arc = EllipseArc::ellipse(e.cx, e.cy, e.rx, e.ry);
            if let Some((brush, op)) = fill_paint(e.fill.as_ref(), e.fill_gradient.as_deref(), bbox) {
                p.fill_ellipse_arc(&arc, FillRule::NonZero, &brush, eff * op);
            }
            if let Some(s) = e.stroke.as_ref() {
                let brush = stroke_brush(s, e.stroke_gradient.as_deref(), elem);
                p.stroke_ellipse_arc(&arc, &brush, &stroke_style(s, s.width), eff * s.opacity);
            }
        }
        Element::Polyline(e) => {
            if !e.points.is_empty() {
                let path = poly_path(&e.points, false);
                let bbox = poly_bbox(&e.points);
                emit_fill_path(p, &path, FillRule::NonZero, e.fill.as_ref(), e.fill_gradient.as_deref(), bbox, eff);
                if let Some(s) = e.stroke.as_ref() {
                    let brush = stroke_brush(s, e.stroke_gradient.as_deref(), elem);
                    emit_path_stroke(p, &path, &brush, s, eff);
                }
            }
        }
        Element::Polygon(e) => {
            if !e.points.is_empty() {
                let path = poly_path(&e.points, true);
                let bbox = poly_bbox(&e.points);
                emit_fill_path(p, &path, FillRule::NonZero, e.fill.as_ref(), e.fill_gradient.as_deref(), bbox, eff);
                if let Some(s) = e.stroke.as_ref() {
                    let brush = stroke_brush(s, e.stroke_gradient.as_deref(), elem);
                    emit_path_stroke(p, &path, &brush, s, eff);
                }
            }
        }
        Element::Path(e) => {
            let bbox = tuple_bounds(elem);
            emit_fill_path(p, &e.d, e.fill_rule, e.fill.as_ref(), e.fill_gradient.as_deref(), bbox, eff);
            if let Some(s) = e.stroke.as_ref() {
                let brush = stroke_brush(s, e.stroke_gradient.as_deref(), elem);
                emit_path_stroke(p, &e.d, &brush, s, eff);
            }
        }
        Element::Text(e) => {
            // A simplified flat FastRun — proves the text op interleaves in
            // z-order (contract: text rides PH1). The production `render.rs`
            // text pipeline stays legacy in PH1 (see `element_needs_legacy`);
            // this lowering is reference-only vocabulary coverage.
            if let Some(f) = e.fill.as_ref() {
                let run = TextRun::FastRun {
                    font: format!("{} {} {}", e.font_style, e.font_weight, e.font_family),
                    size: e.font_size,
                    text: e.content(),
                    letter_spacing: 0.0,
                    x: e.x,
                    y: e.y,
                };
                p.draw_text_run(&run, &Brush::Solid(f.color), eff * f.opacity);
            }
        }
        // Legacy-only or unhandled in the PH1 reference renderer.
        Element::TextPath(_) | Element::Live(_) => {}
    }

    if pushed {
        p.pop_state();
    }
}

// ---------------------------------------------------------------------------
// Paint helpers
// ---------------------------------------------------------------------------

/// Emit a fill of `path` when the element has a fill paint.
fn emit_fill_path(
    p: &mut dyn Painter,
    path: &[PathCommand],
    winding: FillRule,
    fill: Option<&Fill>,
    grad: Option<&Gradient>,
    bbox: (f64, f64, f64, f64),
    eff: f64,
) {
    if let Some((brush, op)) = fill_paint(fill, grad, bbox) {
        p.fill_path(path, winding, &brush, eff * op);
    }
}

/// Emit a stroke of `path` honoring `s.align` via a build-time clip lowering
/// (contract: inside/outside stroke = 2× width clipped to the shape, exactly
/// today's `stroke_aligned`). Center is a bare `stroke_path`.
fn emit_path_stroke(p: &mut dyn Painter, path: &[PathCommand], brush: &Brush, s: &Stroke, eff: f64) {
    let alpha = eff * s.opacity;
    match s.align {
        StrokeAlign::Center => {
            p.stroke_path(path, brush, &stroke_style(s, s.width), alpha);
        }
        StrokeAlign::Inside => {
            // save · clip(path) · stroke(2×) · restore.
            p.push_state(super::Transform::IDENTITY);
            p.clip(path, FillRule::NonZero);
            p.stroke_path(path, brush, &stroke_style(s, s.width * 2.0), alpha);
            p.pop_state();
        }
        StrokeAlign::Outside => {
            // save · clip(path + huge rect, evenodd → outside) · stroke(2×) ·
            // restore. The compound clip path is caller-built (contract A5:
            // clip is path-only; the even-odd outside trick lives at the call
            // site).
            let mut clip_path = path.to_vec();
            clip_path.extend_from_slice(&huge_rect_path());
            p.push_state(super::Transform::IDENTITY);
            p.clip(&clip_path, FillRule::EvenOdd);
            p.stroke_path(path, brush, &stroke_style(s, s.width * 2.0), alpha);
            p.pop_state();
        }
    }
}

/// Resolve the fill paint: `(brush, paint_op)` or `None` when the element has
/// no fill. Mirrors `render.rs::apply_fill`'s decision order (gradient first,
/// then solid).
fn fill_paint(
    fill: Option<&Fill>,
    grad: Option<&Gradient>,
    bbox: (f64, f64, f64, f64),
) -> Option<(Brush, f64)> {
    if let Some(g) = grad {
        if let Some(brush) = resolve_gradient(g, bbox) {
            return Some((brush, fill.map(|f| f.opacity).unwrap_or(1.0)));
        }
    }
    fill.map(|f| (Brush::Solid(f.color), f.opacity))
}

/// Resolve the stroke brush: the stroke gradient (if renderable) else the
/// solid stroke color. Mirrors `render.rs::apply_stroke_with_gradient`.
fn stroke_brush(s: &Stroke, grad: Option<&Gradient>, elem: &Element) -> Brush {
    if let Some(g) = grad {
        if let Some(brush) = resolve_gradient(g, tuple_bounds(elem)) {
            return brush;
        }
    }
    Brush::Solid(s.color)
}

/// The typed stroke style at a given width (width already includes any 2×
/// inside/outside factor and the element-transform counter-scale).
fn stroke_style(s: &Stroke, width: f64) -> StrokeStyle {
    StrokeStyle {
        width,
        cap: s.linecap,
        join: s.linejoin,
        miter: s.miter_limit,
        // Anchor-aligned dashing clears the platform dash (the dasher expands
        // to solid sub-paths); otherwise carry the pattern.
        dash: if s.dash_align_anchors {
            Vec::new()
        } else {
            s.dash_array().to_vec()
        },
    }
}

/// Build a `LinearGradient`/`RadialGradient` brush with endpoints resolved from
/// the element bbox + angle/aspect at BUILD time (contract R3: the Painter
/// never sees `angle`/`aspect_ratio`). Ports `render.rs::make_canvas_gradient`.
/// `None` for a freeform gradient or fewer than two stops.
fn resolve_gradient(g: &Gradient, bbox: (f64, f64, f64, f64)) -> Option<Brush> {
    if g.stops.len() < 2 {
        return None;
    }
    let stops: Vec<ColorStop> = g
        .stops
        .iter()
        .map(|stop| {
            let color = if stop.opacity == 100.0 {
                stop.color
            } else {
                stop.color.with_alpha(stop.opacity / 100.0)
            };
            ColorStop { offset: stop.location / 100.0, color }
        })
        .collect();
    let (bx, by, bw, bh) = bbox;
    match g.gtype {
        GradientType::Linear => {
            let cx = bx + bw / 2.0;
            let cy = by + bh / 2.0;
            let rad = g.angle * std::f64::consts::PI / 180.0;
            let half_diag = (bw * bw + bh * bh).sqrt() / 2.0;
            let dx = rad.cos() * half_diag;
            let dy = -rad.sin() * half_diag; // canvas y is down
            Some(Brush::Linear(LinearGradient {
                x0: cx - dx,
                y0: cy - dy,
                x1: cx + dx,
                y1: cy + dy,
                stops,
            }))
        }
        GradientType::Radial => {
            let cx = bx + bw / 2.0;
            let cy = by + bh / 2.0;
            let r = (bw.max(bh) / 2.0) * (g.aspect_ratio / 100.0).max(0.01);
            Some(Brush::Radial(RadialGradient { x0: cx, y0: cy, r0: 0.0, x1: cx, y1: cy, r1: r, stops }))
        }
        GradientType::Freeform => None,
    }
}

// ---------------------------------------------------------------------------
// Geometry helpers
// ---------------------------------------------------------------------------

fn rounded_rect_path(x: f64, y: f64, w: f64, h: f64, rx_in: f64, ry_in: f64) -> Vec<PathCommand> {
    if rx_in <= 0.0 && ry_in <= 0.0 {
        return vec![
            PathCommand::MoveTo { x, y },
            PathCommand::LineTo { x: x + w, y },
            PathCommand::LineTo { x: x + w, y: y + h },
            PathCommand::LineTo { x, y: y + h },
            PathCommand::ClosePath,
        ];
    }
    let rx = rx_in.max(0.0).min(w / 2.0);
    let ry = ry_in.max(0.0).min(h / 2.0);
    vec![
        PathCommand::MoveTo { x: x + rx, y },
        PathCommand::LineTo { x: x + w - rx, y },
        PathCommand::QuadTo { x1: x + w, y1: y, x: x + w, y: y + ry },
        PathCommand::LineTo { x: x + w, y: y + h - ry },
        PathCommand::QuadTo { x1: x + w, y1: y + h, x: x + w - rx, y: y + h },
        PathCommand::LineTo { x: x + rx, y: y + h },
        PathCommand::QuadTo { x1: x, y1: y + h, x, y: y + h - ry },
        PathCommand::LineTo { x, y: y + ry },
        PathCommand::QuadTo { x1: x, y1: y, x: x + rx, y },
        PathCommand::ClosePath,
    ]
}

fn poly_path(points: &[(f64, f64)], close: bool) -> Vec<PathCommand> {
    let mut cmds = Vec::with_capacity(points.len() + 2);
    cmds.push(PathCommand::MoveTo { x: points[0].0, y: points[0].1 });
    for &(x, y) in &points[1..] {
        cmds.push(PathCommand::LineTo { x, y });
    }
    if close {
        cmds.push(PathCommand::ClosePath);
    }
    cmds
}

fn poly_bbox(pts: &[(f64, f64)]) -> (f64, f64, f64, f64) {
    if pts.is_empty() {
        return (0.0, 0.0, 0.0, 0.0);
    }
    let (mut x_min, mut y_min) = pts[0];
    let (mut x_max, mut y_max) = pts[0];
    for &(x, y) in &pts[1..] {
        if x < x_min {
            x_min = x;
        }
        if x > x_max {
            x_max = x;
        }
        if y < y_min {
            y_min = y;
        }
        if y > y_max {
            y_max = y;
        }
    }
    (x_min, y_min, x_max - x_min, y_max - y_min)
}

/// The element bbox as `(x, y, w, h)` (already a 4-tuple `Bounds`).
fn tuple_bounds(elem: &Element) -> (f64, f64, f64, f64) {
    elem.bounds()
}

/// The `(-1e6,-1e6) 2e6×2e6` rectangle `stroke_aligned` adds for the outside
/// even-odd clip trick, as path commands.
fn huge_rect_path() -> [PathCommand; 5] {
    [
        PathCommand::MoveTo { x: -1e6, y: -1e6 },
        PathCommand::LineTo { x: 1e6, y: -1e6 },
        PathCommand::LineTo { x: 1e6, y: 1e6 },
        PathCommand::LineTo { x: -1e6, y: 1e6 },
        PathCommand::ClosePath,
    ]
}

#[cfg(test)]
mod tests;
