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
    Arrowhead, Color, Element, EllipseElem, Fill, FillRule, Gradient, GradientType,
    LineElem, PathCommand, PathElem, PolygonElem, PolylineElem, RectElem, Stroke, StrokeAlign,
    Visibility,
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
    // ⛔ ACTIVE OPACITY MASK — STILL LEGACY, AND THE PRODUCER EXISTING DOES NOT
    // CHANGE THAT. `emit_element` now emits the full A6 element bracket for a
    // masked element (see `emit_masked_element`), so §6.2's law finally has a
    // producer and is asserted through one. Routing production at it is a
    // SEPARATE step and is BLOCKED IN THE BACKEND:
    //
    //   `Canvas2dPainter::push_mask_layer` / `pop_mask_layer` are still
    //   `unimplemented!()`. #47 landed the LAYER-TARGET half of the backend —
    //   `push_isolated_layer` / `pop_isolated_layer` execute — but the MASK
    //   half is PH4's scratch/luminance pipeline and does not exist.
    //
    // Flipping this clause today would route every masked element into that
    // panic. So the clause stays, deliberately, and this comment is the reason
    // rather than a TODO: backend, THEN the router.
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
    if matches!(elem, Element::Text(_) | Element::TextPath(_) | Element::Live(_)) {
        return true;
    }
    // PH2 production-routing mirror: an element whose `*_painter_inputs` would
    // return `None` (a capability the two-paint seam can't reproduce) stays on
    // legacy in production, so the reference goldens must exclude it too — else
    // they would model a route production never takes.
    match elem {
        // RP3: an ellipse arc carries no align and can't be a clip path, so a
        // non-center circle/ellipse stroke stays legacy.
        Element::Ellipse(e) => stroke_non_center(e.stroke.as_ref()),
        // The legacy Rect arm expands anchor-aligned dashing into sub-paths.
        Element::Rect(e) => e.stroke.as_ref().map(expands_anchor_dash).unwrap_or(false),
        // RP2 (set stroke brush → filled outline), variable width, arrowheads,
        // and anchor-dash expansion are all Path-arm behaviors off the seam.
        Element::Path(e) => {
            e.stroke_brush.is_some()
                || !e.width_points.is_empty()
                || e.stroke
                    .as_ref()
                    .map(|s| has_arrowhead(s) || expands_anchor_dash(s))
                    .unwrap_or(false)
        }
        _ => false,
    }
}

/// A stroke aligned inside/outside rather than centered (RP3 helper).
fn stroke_non_center(s: Option<&Stroke>) -> bool {
    s.map(|s| s.align != StrokeAlign::Center).unwrap_or(false)
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
// Multi-paint production conversion (PH2)
// ---------------------------------------------------------------------------
//
// PH2 extends the PH1 Line pattern to the multi-paint kinds (Rect / Circle /
// Ellipse / Polygon / Polyline / Path). Each `*_painter_inputs` mirrors
// `line_painter_inputs`: it returns the resolved `Painter` inputs IFF the paint
// is display-list-equivalent (contract R4) to `render.rs`'s legacy body — a fill
// (A3 winding, A4 alpha = base·fill_op) THEN a stroke (A4 alpha = base·stroke_op)
// — else `None`, and the caller keeps the unchanged legacy path. Circle/Ellipse
// ride the A2 fill/stroke `ellipse_arc` split.
//
// A capability the legacy arm renders that the two-paint seam can't reproduce
// EXACTLY routes to `None`: a set stroke brush (RP2, Path), variable width,
// arrowheads (Path), anchor-aligned dashing that EXPANDS into sub-paths
// (Rect/Path), inside/outside on an ellipse arc (RP3, Circle/Ellipse), and any
// freeform gradient. `outline` mode is guarded at the call site, exactly as for
// Line. RP1: a gradient (fill OR stroke) resolves its endpoints on the geometry
// bbox the legacy arm passes — supplied by the caller, never `Element::bounds()`.

/// The geometry of a convertible element: a path (Rect / Polygon / Polyline /
/// Path) or the A2 ellipse-arc primitive (Circle / Ellipse).
#[derive(Debug, Clone, PartialEq)]
pub enum ConvGeom {
    Path(Vec<PathCommand>),
    Arc(EllipseArc),
}

/// The resolved fill of a convertible element.
#[derive(Debug, Clone, PartialEq)]
pub struct ConvFill {
    pub brush: Brush,
    pub winding: FillRule,
    /// The fill's paint-time opacity (`Fill::opacity`, today's `fill_op`).
    pub op: f64,
}

/// The resolved stroke of a convertible element. `style.width` is the NOMINAL
/// width; the inside/outside 2× is applied by [`emit_shape_paint`] with the
/// build-time clip, mirroring `render.rs`'s `apply_stroke` + `stroke_aligned`.
#[derive(Debug, Clone, PartialEq)]
pub struct ConvStroke {
    pub brush: Brush,
    pub style: StrokeStyle,
    pub align: StrokeAlign,
    /// The stroke's paint-time opacity (`Stroke::opacity`, today's `stroke_op`).
    pub op: f64,
}

/// The `Painter` inputs for a convertible multi-paint element. Emitted by
/// [`emit_shape_paint`].
#[derive(Debug, Clone, PartialEq)]
pub struct ShapePaint {
    pub geom: ConvGeom,
    pub fill: Option<ConvFill>,
    pub stroke: Option<ConvStroke>,
}

/// Emit a convertible element through `p`: fill THEN stroke, each at
/// `base_alpha × paint_op` (A4). Path strokes honor `align` via the build-time
/// clip lowering (contract A5 / `stroke_aligned`); arc strokes are Center-only
/// by construction (RP3 keeps non-center circles/ellipses on legacy).
pub fn emit_shape_paint(p: &mut dyn Painter, sp: &ShapePaint, base_alpha: f64) {
    if let Some(f) = sp.fill.as_ref() {
        match &sp.geom {
            ConvGeom::Path(path) => p.fill_path(path, f.winding, &f.brush, base_alpha * f.op),
            ConvGeom::Arc(arc) => p.fill_ellipse_arc(arc, f.winding, &f.brush, base_alpha * f.op),
        }
    }
    if let Some(s) = sp.stroke.as_ref() {
        let alpha = base_alpha * s.op;
        match &sp.geom {
            ConvGeom::Arc(arc) => p.stroke_ellipse_arc(arc, &s.brush, &s.style, alpha),
            ConvGeom::Path(path) => {
                emit_aligned_path_stroke(p, path, &s.brush, &s.style, s.align, alpha)
            }
        }
    }
}

/// Stroke `path` honoring `align` (Center = a bare stroke; Inside/Outside = the
/// 2× width clipped to the shape). The same lowering as the reference
/// [`emit_path_stroke`], driven by pre-resolved production inputs.
fn emit_aligned_path_stroke(
    p: &mut dyn Painter,
    path: &[PathCommand],
    brush: &Brush,
    style: &StrokeStyle,
    align: StrokeAlign,
    alpha: f64,
) {
    match align {
        StrokeAlign::Center => p.stroke_path(path, brush, style, alpha),
        StrokeAlign::Inside => {
            p.push_state(super::Transform::IDENTITY);
            p.clip(path, FillRule::NonZero);
            p.stroke_path(path, brush, &doubled(style), alpha);
            p.pop_state();
        }
        StrokeAlign::Outside => {
            let mut clip_path = path.to_vec();
            clip_path.extend_from_slice(&huge_rect_path());
            p.push_state(super::Transform::IDENTITY);
            p.clip(&clip_path, FillRule::EvenOdd);
            p.stroke_path(path, brush, &doubled(style), alpha);
            p.pop_state();
        }
    }
}

/// The stroke style at 2× width for the inside/outside clip lowering (the clip
/// removes the unwanted half — `render.rs::apply_stroke`).
fn doubled(style: &StrokeStyle) -> StrokeStyle {
    StrokeStyle { width: style.width * 2.0, ..style.clone() }
}

/// A gradient that is present AND freeform — never crosses the seam (A5); the
/// element stays legacy.
fn is_freeform(grad: Option<&Gradient>) -> bool {
    grad.map(|g| g.gtype == GradientType::Freeform).unwrap_or(false)
}

/// Anchor-aligned dashing with an active pattern: the legacy Rect/Path arms
/// expand it into solid sub-paths via the dash renderer (not one `stroke_path`).
fn expands_anchor_dash(s: &Stroke) -> bool {
    s.dash_align_anchors && !s.dash_array().is_empty()
}

/// A stroke that draws an arrowhead (setback + arrowhead geometry off the seam).
fn has_arrowhead(s: &Stroke) -> bool {
    s.start_arrow != Arrowhead::None || s.end_arrow != Arrowhead::None
}

/// Resolve the optional fill of `(fill, grad)` into a [`ConvFill`] at `winding`.
fn conv_fill(
    fill: Option<&Fill>,
    grad: Option<&Gradient>,
    bbox: (f64, f64, f64, f64),
    winding: FillRule,
) -> Option<ConvFill> {
    fill_paint(fill, grad, bbox).map(|(brush, op)| ConvFill { brush, winding, op })
}

/// Resolve the optional stroke of an element into a [`ConvStroke`]. `bbox` is the
/// geometry box the legacy arm resolves the stroke gradient on (RP1).
fn conv_stroke(
    stroke: Option<&Stroke>,
    grad: Option<&Gradient>,
    bbox: (f64, f64, f64, f64),
) -> Option<ConvStroke> {
    stroke.map(|s| ConvStroke {
        brush: stroke_brush(s, grad, bbox),
        style: stroke_style(s, s.width),
        align: s.align,
        op: s.opacity,
    })
}

/// Convertible [`Rect`](Element::Rect) inputs, or `None` (legacy). `bbox` is the
/// geometry box `(x, y, w, h)` — the box the legacy Rect arm resolves gradients
/// on (RP1). A plain and a rounded rect both lower to the path form (fill_path +
/// aligned stroke_path), display-list-equivalent to the legacy `fill_rect` /
/// `rect` bodies.
pub fn rect_painter_inputs(e: &RectElem, bbox: (f64, f64, f64, f64)) -> Option<ShapePaint> {
    if is_freeform(e.fill_gradient.as_deref()) || is_freeform(e.stroke_gradient.as_deref()) {
        return None;
    }
    if e.stroke.as_ref().map(expands_anchor_dash).unwrap_or(false) {
        return None;
    }
    Some(ShapePaint {
        geom: ConvGeom::Path(rounded_rect_path(e.x, e.y, e.width, e.height, e.rx, e.ry)),
        fill: conv_fill(e.fill.as_ref(), e.fill_gradient.as_deref(), bbox, FillRule::NonZero),
        stroke: conv_stroke(e.stroke.as_ref(), e.stroke_gradient.as_deref(), bbox),
    })
}

/// Convertible [`Ellipse`](Element::Ellipse) inputs, or `None`. RP3: a
/// non-center stroke stays legacy (an ellipse arc cannot carry the
/// inside/outside clip). Equal radii come through here too -- the circle
/// twin was deleted with the circle kind on 2026-07-30.
pub fn ellipse_painter_inputs(e: &EllipseElem, bbox: (f64, f64, f64, f64)) -> Option<ShapePaint> {
    if is_freeform(e.fill_gradient.as_deref()) || is_freeform(e.stroke_gradient.as_deref()) {
        return None;
    }
    if stroke_non_center(e.stroke.as_ref()) {
        return None;
    }
    Some(ShapePaint {
        geom: ConvGeom::Arc(EllipseArc::ellipse(e.cx, e.cy, e.rx, e.ry)),
        fill: conv_fill(e.fill.as_ref(), e.fill_gradient.as_deref(), bbox, FillRule::NonZero),
        stroke: conv_stroke(e.stroke.as_ref(), e.stroke_gradient.as_deref(), bbox),
    })
}

/// Convertible [`Polygon`](Element::Polygon) inputs, or `None`. An empty point
/// list stays legacy (paints nothing either way). Inside/outside strokes ride
/// the path clip lowering.
pub fn polygon_painter_inputs(e: &PolygonElem, bbox: (f64, f64, f64, f64)) -> Option<ShapePaint> {
    if e.points.is_empty() {
        return None;
    }
    if is_freeform(e.fill_gradient.as_deref()) || is_freeform(e.stroke_gradient.as_deref()) {
        return None;
    }
    Some(ShapePaint {
        geom: ConvGeom::Path(poly_path(&e.points, true)),
        fill: conv_fill(e.fill.as_ref(), e.fill_gradient.as_deref(), bbox, FillRule::NonZero),
        stroke: conv_stroke(e.stroke.as_ref(), e.stroke_gradient.as_deref(), bbox),
    })
}

/// Convertible [`Polyline`](Element::Polyline) inputs, or `None`. Like Polygon
/// but the path is not closed.
pub fn polyline_painter_inputs(e: &PolylineElem, bbox: (f64, f64, f64, f64)) -> Option<ShapePaint> {
    if e.points.is_empty() {
        return None;
    }
    if is_freeform(e.fill_gradient.as_deref()) || is_freeform(e.stroke_gradient.as_deref()) {
        return None;
    }
    Some(ShapePaint {
        geom: ConvGeom::Path(poly_path(&e.points, false)),
        fill: conv_fill(e.fill.as_ref(), e.fill_gradient.as_deref(), bbox, FillRule::NonZero),
        stroke: conv_stroke(e.stroke.as_ref(), e.stroke_gradient.as_deref(), bbox),
    })
}

/// Convertible [`Path`](Element::Path) inputs, or `None`. `bbox` is
/// `elem.bounds()` — the box the legacy Path arm resolves gradients on (RP1;
/// for Path that box IS `bounds()`). RP2: a set `stroke_brush` renders a filled
/// outline, nothing like a native stroke → legacy. Variable width, arrowheads,
/// and anchor-dash expansion likewise stay legacy. The A3 fill winding is the
/// element's `fill_rule` (EvenOdd for boolean-op holes).
pub fn path_painter_inputs(e: &PathElem, bbox: (f64, f64, f64, f64)) -> Option<ShapePaint> {
    if is_freeform(e.fill_gradient.as_deref()) || is_freeform(e.stroke_gradient.as_deref()) {
        return None;
    }
    if e.stroke_brush.is_some() || !e.width_points.is_empty() {
        return None;
    }
    if e
        .stroke
        .as_ref()
        .map(|s| has_arrowhead(s) || expands_anchor_dash(s))
        .unwrap_or(false)
    {
        return None;
    }
    Some(ShapePaint {
        geom: ConvGeom::Path(e.d.clone()),
        fill: conv_fill(e.fill.as_ref(), e.fill_gradient.as_deref(), bbox, e.fill_rule),
        stroke: conv_stroke(e.stroke.as_ref(), e.stroke_gradient.as_deref(), bbox),
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
/// The element's ACTIVE mask, or `None`. A `disabled` mask is not active —
/// the element renders as if none were attached, which is what the legacy
/// `mask_plan` says too (it returns `None` for a disabled mask).
#[allow(dead_code)] // Not-yet-wired: reachable only when `element_needs_legacy` stops routing
// masked elements to legacy. Exercised by the A6 producer tests today.
fn active_mask(elem: &Element) -> Option<&crate::geometry::element::Mask> {
    elem.common().mask.as_deref().filter(|m| !m.disabled)
}

/// AMENDMENT A6 — emit one masked element as THE ELEMENT BRACKET.
///
/// ```text
/// push_isolated_layer(own opacity, own blend)
///     <body ops>                     — under the element's own transform
///     push_mask_layer(law)
///         <mask artwork ops>         — under the mask's EFFECTIVE transform
///     pop_mask_layer()
/// pop_isolated_layer()
/// ```
///
/// WHERE EACH PIECE COMES FROM, because none of it is invented here:
///
/// - **The law** is [`mask_from_flags`](crate::painter::mask_from_flags), the
///   ONE copy of the `(clip, invert)` truth table (A6 §4 puts the lowering at
///   BUILD time). `bbox` is the mask subtree's bounds, computed HERE and passed
///   in — a backend never computes bounds (§3.3), and it is the same
///   `mask.subtree.bounds()` the legacy `RevealOutsideBbox` arm reads.
/// - **The body's alpha is `incoming_alpha`, NOT `incoming_alpha *
///   elem.opacity()`.** The element's own opacity rides the LAYER and is spent
///   once at `pop_isolated_layer`; multiplying it into the body as well is
///   defect D-α's first half, and §6.2's golden exists to pin exactly that.
/// - **The mask artwork's alpha is 1.0.** The mask bracket is itself isolated —
///   fresh transparent surface, alpha context 1.0 (§3.2). Legacy agrees: it
///   resets the scratch context's alpha to 1.0 before drawing the subtree.
/// - **The mask transform** is `elem.transform()` when the mask is linked and
///   `unlink_transform` when it is not — `render.rs::effective_mask_transform`,
///   ported rather than re-derived. It is pushed AFTER the body's own transform
///   has popped, because legacy applies it from the ancestor coordinate system,
///   not on top of the element's.
///
/// ⛔ THIS IS NOT BEHAVIOR-PRESERVING, AND THAT IS RATIFIED, NOT OVERLOOKED.
/// Contract R4 converts only what is behavior-preserving; A6 §6.2 deliberately
/// pins a law HEAD violates. HEAD renders a masked element inside an alpha
/// group at `own²`, because `set_global_alpha` REPLACES rather than multiplies,
/// so the ancestors' contribution is discarded and the element's own opacity is
/// applied twice. The bracket applies each factor ONCE. ⇒ Converting a masked
/// element under an alpha ancestor CHANGES what is drawn — to the ratified law.
/// It is stated here because a reader of a diff would otherwise have to
/// rediscover it.
#[allow(dead_code)] // Not-yet-wired: same reason as `active_mask` — the router flip is a
// separate, ratified behaviour change. The tests drive this path directly.
fn emit_masked_element(
    p: &mut dyn Painter,
    elem: &Element,
    mask: &crate::geometry::element::Mask,
    incoming_alpha: f64,
) {
    let (bx, by, bw, bh) = mask.subtree.bounds();
    let law = crate::painter::mask_from_flags(
        mask.clip,
        mask.invert,
        Rect { x: bx, y: by, w: bw, h: bh },
    );

    p.push_isolated_layer(elem.opacity(), elem.common().mode);
    // The body: ancestors ride the paint alpha (this producer FOLDS group
    // alpha rather than emitting `push_group`), the element's own opacity
    // rides the layer above.
    emit_element_body(p, elem, incoming_alpha);

    p.push_mask_layer(law);
    let mask_xf = if mask.linked {
        elem.transform()
    } else {
        mask.unlink_transform.as_ref()
    };
    let pushed = mask_xf.is_some();
    if let Some(t) = mask_xf {
        p.push_state(*t);
    }
    emit_element(p, &mask.subtree, 1.0);
    if pushed {
        p.pop_state();
    }
    p.pop_mask_layer();
    // Nothing paints between pop_mask_layer and pop_isolated_layer (§3.2).
    p.pop_isolated_layer();
}

pub fn emit_element(p: &mut dyn Painter, elem: &Element, incoming_alpha: f64) {
    if elem.visibility() == Visibility::Invisible {
        return;
    }
    // AMENDMENT A6 — an element with an ACTIVE mask is emitted as the element
    // bracket, not as a bare body. See `emit_masked_element` for the derivation.
    if let Some(mask) = active_mask(elem) {
        emit_masked_element(p, elem, mask, incoming_alpha);
        return;
    }
    emit_element_body(p, elem, incoming_alpha * elem.opacity());
}

/// The element's own paint ops at a GIVEN effective alpha, under its own
/// transform. Split out of [`emit_element`] so the A6 bracket can emit the same
/// body at a DIFFERENT alpha: inside an isolated layer the element's own
/// opacity rides the layer and must not also multiply into the body primitives.
///
/// `eff` is the final paint-alpha base — already multiplied by whatever opacity
/// applies. The split is otherwise behavior-neutral: the unmasked call passes
/// `incoming_alpha * elem.opacity()`, which is exactly what this computed before.
fn emit_element_body(p: &mut dyn Painter, elem: &Element, eff: f64) {
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
                let brush = stroke_brush(s, e.stroke_gradient.as_deref(), tuple_bounds(elem));
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
                    let brush = stroke_brush(s, e.stroke_gradient.as_deref(), bbox);
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
                    let brush = stroke_brush(s, e.stroke_gradient.as_deref(), bbox);
                    if s.align == StrokeAlign::Center {
                        p.stroke_rect(rect, &brush, &stroke_style(s, s.width), eff * s.opacity);
                    } else {
                        let path = rounded_rect_path(e.x, e.y, e.width, e.height, 0.0, 0.0);
                        emit_path_stroke(p, &path, &brush, s, eff);
                    }
                }
            }
        }
        Element::Ellipse(e) => {
            let bbox = (e.cx - e.rx, e.cy - e.ry, e.rx * 2.0, e.ry * 2.0);
            let arc = EllipseArc::ellipse(e.cx, e.cy, e.rx, e.ry);
            if let Some((brush, op)) = fill_paint(e.fill.as_ref(), e.fill_gradient.as_deref(), bbox) {
                p.fill_ellipse_arc(&arc, FillRule::NonZero, &brush, eff * op);
            }
            if let Some(s) = e.stroke.as_ref() {
                let brush = stroke_brush(s, e.stroke_gradient.as_deref(), bbox);
                p.stroke_ellipse_arc(&arc, &brush, &stroke_style(s, s.width), eff * s.opacity);
            }
        }
        Element::Polyline(e) => {
            if !e.points.is_empty() {
                let path = poly_path(&e.points, false);
                let bbox = poly_bbox(&e.points);
                emit_fill_path(p, &path, FillRule::NonZero, e.fill.as_ref(), e.fill_gradient.as_deref(), bbox, eff);
                if let Some(s) = e.stroke.as_ref() {
                    let brush = stroke_brush(s, e.stroke_gradient.as_deref(), bbox);
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
                    let brush = stroke_brush(s, e.stroke_gradient.as_deref(), bbox);
                    emit_path_stroke(p, &path, &brush, s, eff);
                }
            }
        }
        Element::Path(e) => {
            let bbox = tuple_bounds(elem);
            emit_fill_path(p, &e.d, e.fill_rule, e.fill.as_ref(), e.fill_gradient.as_deref(), bbox, eff);
            if let Some(s) = e.stroke.as_ref() {
                let brush = stroke_brush(s, e.stroke_gradient.as_deref(), bbox);
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
///
/// RP1: `bbox` is the GEOMETRY box the legacy arm resolves the gradient on
/// (Rect passes `(x,y,w,h)`; Path passes `elem.bounds()`) — NOT blindly
/// `Element::bounds()`, which inflates by half the stroke width and would land
/// a gradient STROKE on the wrong endpoints. The caller supplies it.
fn stroke_brush(s: &Stroke, grad: Option<&Gradient>, bbox: (f64, f64, f64, f64)) -> Brush {
    if let Some(g) = grad {
        if let Some(brush) = resolve_gradient(g, bbox) {
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
            let rad = g.angle.to_radians();
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
