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
//! 2. **The capability router** [`element_needs_legacy`] — which takes the
//!    BACKEND's answers, not only the element — and the byte-identical
//!    leaf-paint helper [`line_painter_inputs`] — the PH3 production slice.
//!    `render.rs` routes an element that needs a PH3 feature (type-on-path /
//!    placed-glyph text, freeform gradient) to the legacy raw-`ctx` path
//!    unchanged. ⚖️ AN OPACITY MASK IS NO LONGER IN THAT LIST: since PH4 a
//!    masked element whose WHOLE SUBTREE converts takes the A6 bracket in
//!    production too — see [`subtree_needs_legacy`], which is the router
//!    production asks and which this shallow one is not a substitute for. The
//!    one PH1 leaf paint that is proven
//!    byte-identical to `render.rs` today — a plain center-aligned, solid,
//!    arrowless [`Line`](Element::Line) — routes through a
//!    [`Canvas2dPainter`](super::canvas2d::Canvas2dPainter). See
//!    `line_painter_inputs` for the exact equivalence argument.
//!
//! EXCLUDED, AND FOR THREE DIFFERENT REASONS — the distinction matters because
//! only one of them can ever change by itself:
//! - **opacity masks** — NO LONGER EXCLUDED CATEGORICALLY (council 08/29, row
//!   (e) = option (b)). A masked element takes the A6 element bracket on a
//!   backend that answers yes to both halves, and stays legacy on one that does
//!   not. That is a BACKEND question now, asked through
//!   [`Painter::supports`](super::Painter::supports).
//! - **type-on-path / placed-glyph text** (PH3) — net-new shaping work that
//!   exists in no backend, so there is deliberately no capability for it.
//! - **freeform gradients** — a build-time lowering concern the seam never
//!   carries (contract A5); no backend answer unlocks it either.

use crate::geometry::element::{
    Arrowhead, Color, Element, EllipseElem, Fill, FillRule, Gradient, GradientType,
    LineElem, PathCommand, PathElem, PolygonElem, PolylineElem, RectElem, Stroke, StrokeAlign,
    Visibility,
};

use super::capability::{Capability, Caps};
use super::{
    Brush, ColorStop, EllipseArc, LinearGradient, Painter, RadialGradient, Rect, StrokeStyle,
    TextRun,
};

// ---------------------------------------------------------------------------
// Capability router (PH3 production slice)
// ---------------------------------------------------------------------------

/// Does this element need something the route in front of it cannot deliver?
/// Such elements STAY on the legacy raw-`ctx` path (contract R4: convert only
/// what is behavior-preserving).
///
/// ⚖️ IT TAKES `caps` BECAUSE THE ANSWER IS NOT A PROPERTY OF THE ELEMENT ALONE
/// (council 08/29, row (e) = option (b)). This router routes THE SEAM, and the
/// seam has two backends: `Canvas2dPainter` executes isolated layers (#47) and
/// mask layers (#55); `Direct2DPainter` executes neither. Asking only about the
/// element forces one answer onto both — pinning Canvas2D to legacy forever, or
/// routing Direct2D into an `unimplemented!()`. So the caller passes what the
/// backend it is about to paint through actually answers ([`Caps::of`]).
///
/// THE TWO CLAUSES ARE DIFFERENT KINDS OF "NO", and the distinction is
/// load-bearing:
///
/// - **backend questions** — an active [`Mask`](crate::geometry::element::Mask)
///   needs the A6 element bracket, which needs BOTH
///   [`Capability::IsolatedLayers`] and [`Capability::MaskLayers`]. Half the
///   bracket is not the bracket: A6 §3.2 makes a mask legal only inside an
///   isolated layer, so a backend with layers and no masks — Canvas2D from #47
///   to #55, and the state Direct2D will pass through — must stay legacy. The
///   corpus can express that state only because `a6_layer_no_mask.json` exists;
///   see [`capability`](crate::painter::capability).
/// - **not backend questions, and there is no capability for them** — a
///   freeform gradient is a build-time lowering concern that never crosses the
///   seam (contract A5); text/type-on-path is PH3 net-new shaping work; the
///   `*_painter_inputs` mirrors below are properties of the two-paint seam
///   itself. No backend answer unlocks any of these, and inventing a capability
///   for them would ask backends a question they cannot answer.
pub fn element_needs_legacy(elem: &Element, caps: Caps) -> bool {
    // ⛔ AN ACTIVE OPACITY MASK IS NOW A QUESTION ABOUT THE BACKEND, AND THIS IS
    // THE FLIP. It used to be an unconditional `return true` — correct while
    // `Canvas2dPainter::push_mask_layer` was `unimplemented!()`, and stale from
    // the moment #55 landed, because nothing about the ELEMENT had ever been
    // the reason. #47 gave the layer half, #55 the mask half; what was missing
    // was a way to ask, and asking is what option (b) added.
    //
    // ⚠️ THE FLIP IS A RATIFIED BEHAVIOUR CHANGE (A6 §6.2), NOT A REFACTOR: a
    // masked element whose body OVERLAPS ITSELF renders DIFFERENTLY once it
    // takes the bracket. See `emit_masked_element` for the law — including the
    // correction to what this comment used to blame it on (D-α, which was
    // already repaired in production when the claim was written).
    if let Some(_mask) = active_mask(elem) {
        // WHAT THE BRACKET WILL ASK OF THE BACKEND, built as a SET and compared
        // whole. `emit_masked_element` emits
        // `push_isolated_layer(elem.opacity(), elem.common().mode)` — the ONLY
        // place a blend crosses this seam (groups fold their alpha and emit no
        // `push_group`, per D3). So an element whose own mode is non-Normal
        // needs the effect graph as well as the layer and the mask.
        //
        // ⛔ THE BLEND CLAUSE IS NOT DECORATION — it is condition (i) at the
        // routing end. Without it, a masked element carrying `multiply` routes
        // to any backend that answers yes to layers+masks, and a backend that
        // opens the layer while never reading its `blend` DISCARDS the multiply
        // with nothing reporting it. Refusing to route is the only protection
        // the router can give against a silent discard.
        let mut required = Caps::NONE
            .with(Capability::IsolatedLayers)
            .with(Capability::MaskLayers);
        if elem.common().mode != crate::painter::BlendMode::Normal {
            required = required.with(Capability::NonNormalBlend);
        }
        if !caps.supplies(required) {
            return true;
        }
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
    // Text / type-on-path. ⭐ LIVE GEOMETRY LEFT THIS CLAUSE IN ROW CV, and the
    // clause is NARROWED rather than deleted: text is PH3 shaping work this seam
    // has no vocabulary for, and a wider edit would silently put it on a path
    // that cannot draw it. The reason live geometry was here — "there is no live
    // lowering on the Painter" — is gone, not merely inconvenient: `emit_element`
    // now takes the core's own four `evaluate_with` arms and draws the OUTPUT as
    // geometry (the helm's 2026-09-01 design word), which is what a Windows app
    // renders, with `canvas::render` not involved at all.
    if matches!(elem, Element::Text(_) | Element::TextPath(_)) {
        return true;
    }
    // ⭐ OUTLINE MODE IS NO LONGER A LEGACY REASON (node 2). This clause used to
    // read `if elem.visibility() == Visibility::Outline { return true }`, and
    // its stated ground was that *"there is no outline lowering on the
    // Painter"*. There is one now -- `emit_outline_body`, ported from
    // `render.rs::apply_outline_style` -- so the reason is gone rather than
    // merely inconvenient, and a clause kept past its reason is one nothing
    // drives.
    //
    // ⚠️ ONE PRODUCTION ROUTE CHANGES, AND IT IS NAMED RATHER THAN DISCOVERED.
    // `render.rs` reads this router in exactly one reachable place --
    // `draw_masked_element_through_the_seam` (via `subtree_needs_legacy`). Its
    // SIX leaf routes each guard outline themselves (`let converted = if
    // outline { false } else ...`) and are untouched.
    //
    // ⇒ The single consequence: **a masked element in outline mode now takes
    // the A6 element bracket instead of the legacy mask composite.** Both
    // OUTLINE it -- that equivalence is pinned by
    // `an_outline_element_converts_and_an_outlined_descendant_no_longer_forces_legacy`
    // -- so the difference between them is only the ratified A6 one (§6.2: a
    // body that overlaps ITSELF composites differently), which every other
    // masked element has taken since PH4. This extends that ruling to outlined
    // ones rather than making a new decision.
    //
    // ⭐ AND THE REAL POINT IS THE OTHER CALLER. Any NATIVE walk of a document
    // through `emit_element` now gets outline mode -- which is how a Windows
    // app renders it, with `canvas::render` not involved at all.
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

/// **The PRODUCTION router.** Does this element, ITS WHOLE SUBTREE, and (when
/// it carries an active mask) THE MASK ARTWORK'S whole subtree, convert on
/// `caps`?
///
/// ⛔ WHY A SECOND FUNCTION AND NOT A DEEPER [`element_needs_legacy`].
/// The shallow answer is the RIGHT one for the reference renderer: its corpora
/// are PH1-expressible by construction, and its goldens exist to pin one
/// element's lowering. It is the WRONG one for production, and the difference
/// is not a matter of degree — it is content loss:
///
/// - **A legacy-only DESCENDANT of a masked element is dropped.**
///   [`emit_element`] returns without painting for an element that needs
///   legacy, so a masked group holding a freeform-gradient child emits the
///   bracket and simply omits the child. Nothing reports it.
/// - **Legacy-only MASK ARTWORK deletes the ELEMENT.** `LuminanceClipIn` is
///   `α_S ← α_S · M`; artwork that paints nothing gives `M = 0` everywhere, so
///   the masked element vanishes rather than degrades. This is a DIFFERENT
///   failure from the first, which is why it has its own arm in the tests.
///
/// Neither can happen on the leaf-paint routes production already takes: those
/// convert ONE paint of ONE element and fall back in place. The A6 bracket is
/// the first production route that swallows a subtree, so it is the first that
/// needs to ask about one.
///
/// ⚠️ VISIBILITY IS NOT SPECIAL-CASED, DELIBERATELY. An `Invisible` descendant
/// paints nothing on either path and could safely be skipped; it is walked
/// anyway, because the only cost of walking it is that a document converts less
/// often, and the only cost of skipping it wrongly is a silent divergence. The
/// conservative direction here is the legacy one — it is what ships today.
pub fn subtree_needs_legacy(elem: &Element, caps: Caps) -> bool {
    if element_needs_legacy(elem, caps) {
        return true;
    }
    if let Some(m) = active_mask(elem) {
        if subtree_needs_legacy(&m.subtree, caps) {
            return true;
        }
    }
    if let Some(children) = elem.children() {
        if children.iter().any(|c| subtree_needs_legacy(c, caps)) {
            return true;
        }
    }
    false
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
///   BUILD time). `bbox` is computed HERE and passed in — a backend never
///   computes bounds (§3.3) — and per the ruled contract (the helm's design
///   word, 2026-08-31) it is the axis-aligned bounds OF the transformed mask
///   subtree: `mask.subtree.bounds()` taken through the mask's effective
///   transform by [`aabb_through`](crate::geometry::element::aabb_through),
///   in the frame where `pop_mask_layer` applies the clip (the element's
///   parent frame). Never `mask_xf · bounds` as a region — a rotation makes
///   that inexpressible in an axis-aligned `Rect`. The legacy
///   `RevealOutsideBbox` arm computes the identical value with the identical
///   helper, which is what keeps the two paths in pixel agreement.
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
/// pins a law the legacy composite violates.
///
/// ⚠️ AND IT IS NOT THE `own²` DEFECT — THAT SENTENCE WAS STALE WHEN IT WAS
/// WRITTEN, AND IS CORRECTED HERE. It read: "HEAD renders a masked element
/// inside an alpha group at `own²` … the ancestors' contribution is discarded".
/// That was D-α, and it was repaired in `canvas/render.rs` on 2026-08-24
/// (`mask_blit_alpha`, commit `c59e5349`) — five days before this comment was
/// authored. Production has rendered `ancestors × own` ever since. The example
/// the claim travelled with (own 0.5 in a 0.5 group) yields 0.25 under BOTH the
/// defect and the law, which is precisely why nobody re-derived it: **the
/// witness offered for the change could not have distinguished it.**
///
/// WHAT ACTUALLY CHANGES, measured in headless Chrome on 2026-08-30
/// (`canvas::render::ph4_conversion_tests`): **which factor is isolated.**
///
/// ```text
///                        the element's own opacity     the ancestor product
///   legacy composite     per-primitive (compounds)     once, on the scratch
///   A6 bracket           once, at the composite        per-primitive (compounds)
/// ```
///
/// The contract pins group alpha as NON-isolated and A6 makes the masked
/// element an ISOLATED layer carrying its own opacity; the legacy composite has
/// both the wrong way round. For a single-primitive body the two agree exactly
/// at `ancestors × own` — they diverge, in BOTH directions, only where the
/// masked element's body overlaps itself.
fn emit_masked_element(
    p: &mut dyn Painter,
    elem: &Element,
    mask: &crate::geometry::element::Mask,
    incoming_alpha: f64,
    vis: Visibility,
) {
    let mask_xf = if mask.linked {
        elem.transform()
    } else {
        mask.unlink_transform.as_ref()
    };
    // The ruled §3.3 contract: bounds AFTER the mask's effective transform,
    // in the frame the clip is applied in. Same helper as legacy's arm.
    let (bx, by, bw, bh) = match mask_xf {
        Some(t) => crate::geometry::element::aabb_through(mask.subtree.bounds(), t),
        None => mask.subtree.bounds(),
    };
    let law = crate::painter::mask_from_flags(
        mask.clip,
        mask.invert,
        Rect { x: bx, y: by, w: bw, h: bh },
    );

    p.push_isolated_layer(elem.opacity(), elem.common().mode);
    // The body: ancestors ride the paint alpha (this producer FOLDS group
    // alpha rather than emitting `push_group`), the element's own opacity
    // rides the layer above.
    emit_element_body(p, elem, incoming_alpha, vis);

    p.push_mask_layer(law);
    let pushed = mask_xf.is_some();
    if let Some(t) = mask_xf {
        p.push_state(*t);
    }
    // ⛔ `Preview`, NOT `vis`. The mask subtree is not part of the picture -- it
    // is COVERAGE, read for its alpha (or luminance). Outlining it would replace
    // the artwork that defines the mask with a hairline tracing its silhouette,
    // which is a different mask, not a differently-drawn one. `render.rs` draws
    // mask artwork through its own path and never applies the outline style to
    // it either.
    emit_element_with_vis(p, &mask.subtree, 1.0, Visibility::Preview);
    if pushed {
        p.pop_state();
    }
    p.pop_mask_layer();
    // Nothing paints between pop_mask_layer and pop_isolated_layer (§3.2).
    p.pop_isolated_layer();
}

pub fn emit_element(p: &mut dyn Painter, elem: &Element, incoming_alpha: f64) {
    // A top-level element inherits nothing, which is `Preview` -- the same seed
    // `render.rs::draw_element` uses.
    emit_element_with_vis(p, elem, incoming_alpha, Visibility::Preview);
}

/// [`emit_element`] carrying the INHERITED visibility from the ancestor chain.
///
/// ⭐ NODE 2 -- THE DELTA `render.rs` HAD AND THIS SEAM DID NOT. Visibility is
/// not a property of the element alone: `draw_element_scaled` computes
/// `effective = min(ancestor_vis, elem.visibility())`, so a group in outline
/// mode drags every descendant into outline even where the child's own
/// visibility is `Preview`. `emit_element` reads only the element in its hand
/// and therefore could not express that.
///
/// ⛔ THAT GAP IS NAMED IN PRODUCTION, not inferred here.
/// `render.rs::draw_masked_element_through_the_seam`'s condition 1 refuses to
/// convert anything whose `ancestor_vis` is not `Preview`, in as many words:
/// *"the seam has no outline lowering and no invisible cap; both are inherited
/// state this function cannot see from the element alone."* This is that state,
/// made visible.
///
/// `Visibility` orders `Invisible < Outline < Preview`, so `min` gives both
/// rules at once: an invisible cap outranks outline, and outline outranks
/// preview in either direction.
pub fn emit_element_with_vis(
    p: &mut dyn Painter,
    elem: &Element,
    incoming_alpha: f64,
    ancestor_vis: Visibility,
) {
    let vis = ancestor_vis.min(elem.visibility());
    if vis == Visibility::Invisible {
        return;
    }
    // ⛔ THE PRECONDITION IS ENFORCED, NOT ASSUMED, AND THIS IS THE ONE PLACE.
    // This function's contract has always read "assumes `!element_needs_legacy`;
    // a legacy-only element paints nothing" — a caller's duty, dischargeable
    // only while the answer was a constant. It is a question about the BACKEND
    // now, so the function that has the backend in its hand is the one that asks.
    // Every caller, including the group-children loop below, is covered by this
    // single check rather than by a copy of it.
    if element_needs_legacy(elem, Caps::of(&*p)) {
        return;
    }
    // AMENDMENT A6 — an element with an ACTIVE mask is emitted as the element
    // bracket, not as a bare body. See `emit_masked_element` for the derivation.
    if let Some(mask) = active_mask(elem) {
        emit_masked_element(p, elem, mask, incoming_alpha, vis);
        return;
    }
    emit_element_body(p, elem, incoming_alpha * elem.opacity(), vis);
}

/// The element's own paint ops at a GIVEN effective alpha, under its own
/// transform. Split out of [`emit_element`] so the A6 bracket can emit the same
/// body at a DIFFERENT alpha: inside an isolated layer the element's own
/// opacity rides the layer and must not also multiply into the body primitives.
///
/// `eff` is the final paint-alpha base — already multiplied by whatever opacity
/// applies. The split is otherwise behavior-neutral: the unmasked call passes
/// `incoming_alpha * elem.opacity()`, which is exactly what this computed before.
fn emit_element_body(p: &mut dyn Painter, elem: &Element, eff: f64, vis: Visibility) {
    let pushed = elem.transform().is_some();
    if let Some(t) = elem.transform() {
        p.push_state(*t);
    }

    match elem {
        Element::Group(_) | Element::Layer(_) => {
            if let Some(children) = elem.children() {
                // The router is NOT consulted here: `emit_element` asks it, once,
                // for every element including these children. Filtering here as
                // well was redundant by construction — and a mutation pass proved
                // it: replacing this site's capability read with a hardcoded
                // all-yes changed no test, because the check one frame in caught
                // every case. Two guards with the same predicate cannot both be
                // driven, and the undriven one is the one that rots.
                for child in children {
                    // THE INHERITED VISIBILITY TRAVELS WITH THE ALPHA. Both are
                    // ancestor state, and a child that read only its own would
                    // paint a hidden layer or a solid fill under an outlined
                    // group.
                    emit_element_with_vis(p, child, eff, vis);
                }
            }
        }
        // ⭐ OUTLINE MODE -- the node-2 delta, ported from
        // `render.rs::apply_outline_style`. It REPLACES both paints rather than
        // adding one: no fill at all, and a single black 1px butt/miter
        // hairline with no dash over the element's own geometry. Placed after
        // the Group arm so a group still recurses (its children each outline
        // themselves) and before every leaf arm so no leaf can paint its normal
        // fill and stroke.
        _ if vis == Visibility::Outline => emit_outline_body(p, elem, eff),
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
        // ⭐ ROW CV -- LIVE GEOMETRY, ported from `render.rs`'s `Element::Live`
        // arm. The element IS its evaluated output: one traced path over the
        // rings, filled and stroked with the live element's own paint. See
        // [`live_paint`] for where the geometry and the paint come from.
        Element::Live(v) => {
            let (rings, live_fill, live_stroke) = live_paint(v);
            let path = live_rings_path(&rings);
            // ⛔ EMPTY GEOMETRY EMITS NOTHING AT ALL -- not an empty fill, not a
            // begin/close pair. `render.rs` guards the whole block on
            // `ps.iter().any(|r| r.len() >= 2)`, and that guard is the uniform
            // failure rule's visible half: a dangling reference, an unknown
            // concept and a cycle all arrive here as an empty ring set.
            if !path.is_empty() {
                // ⚖️ NO GRADIENT, AND THAT IS THE MODEL'S ANSWER RATHER THAN A
                // SIMPLIFICATION: `Element::fill_gradient`/`stroke_gradient`
                // return `None` for every `Live` variant -- live elements carry
                // no gradient field at all -- which is why legacy's Live arm
                // calls `apply_fill(.., None, (0,0,0,0))` and the plain
                // `apply_stroke`. The bbox below is therefore never read.
                // ⛔ ROW EH -- THE RULE COMES FROM THE PRODUCER, NOT FROM THE
                // RENDERER. These rings are the algorithm layer's own output,
                // and BOOLEAN.md's carried-rule law (clause 4) declares such a
                // result EVEN-ODD. `FillRule::NonZero` stood here until 09/02
                // and refilled every hole a `SubtractFront` cut: the cutter's
                // interior sits inside two co-oriented rings, so its winding is
                // ±2. Derived from the constant rather than spelled, so the two
                // cannot drift.
                emit_fill_path(p, &path,
                               FillRule::from(crate::algorithms::boolean::RESULT_FILL_RULE),
                               live_fill.as_ref(), None,
                               (0.0, 0.0, 0.0, 0.0), eff);
                if let Some(s) = live_stroke.as_ref() {
                    emit_path_stroke(p, &path, &Brush::Solid(s.color), s, eff);
                }
            }
        }
        // Legacy-only or unhandled in the PH1 reference renderer.
        Element::TextPath(_) => {}
    }

    if pushed {
        p.pop_state();
    }
}

// ---------------------------------------------------------------------------
// Live geometry (row CV)
// ---------------------------------------------------------------------------

/// The evaluated rings of a live element and the paint to draw them with.
///
/// ⭐ THE FOUR ARMS ARE THE CORE'S OWN CONTRACT, NOT A NATIVE GENERATOR. Each
/// variant's `evaluate_with(precision, resolver, visiting)` is the same call
/// `canvas::render` makes; nothing here evaluates geometry itself, and nothing
/// here bakes a snapshot. A cycle guard is a fresh local per top-level evaluate,
/// exactly as legacy does it.
///
/// ⭐ THE AMBIENT STATE COMES FROM THE INSTALLED PAINT CONTEXT. `canvas::render`
/// has a `precision` parameter threaded down its whole draw stack and a
/// render-scoped index it installs; `emit_element` has neither and cannot grow
/// them without changing a ratified signature every backend and caller shares.
/// Row CV made both ONE install in `document::id_index`, which both walks read
/// -- see [`crate::document::paint::emit_document`] for the native caller that
/// performs it, and the module docs there for why a missing install is silent.
///
/// ⚖️ FORK F3 IS THE ONE PLACE THE VARIANTS DIFFER: a `Reference` whose own
/// fill/stroke is unset inherits the RESOLVED TARGET's. The other three carry
/// their own paint and inherit nothing. Treating the four uniformly would draw
/// an unpainted instance of a painted master.
fn live_paint(
    v: &crate::geometry::live::LiveVariant,
) -> (crate::algorithms::boolean::PolygonSet, Option<Fill>, Option<Stroke>) {
    use crate::geometry::live::LiveVariant;
    let precision = crate::document::id_index::installed_precision();
    let resolver = crate::document::id_index::InstalledResolver;
    let mut visiting = crate::geometry::live::VisitSet::new();
    match v {
        LiveVariant::CompoundShape(cs) => (
            cs.evaluate_with(precision, &resolver, &mut visiting),
            cs.fill.clone(),
            cs.stroke.clone(),
        ),
        LiveVariant::Reference(r) => {
            let rings = r.evaluate_with(precision, &resolver, &mut visiting);
            // F3: the resolved target supplies whichever paint the reference
            // leaves unset. Resolved through the SAME resolver the evaluation
            // used, so paint and geometry cannot disagree about the target.
            let target = crate::geometry::live::ElementResolver::resolve(&resolver, &r.target);
            let fill = r.fill.clone().or_else(|| target.as_ref().and_then(|t| t.fill().cloned()));
            let stroke =
                r.stroke.clone().or_else(|| target.as_ref().and_then(|t| t.stroke().cloned()));
            (rings, fill, stroke)
        }
        // A recorded element renders its replayed (derived) geometry, resolved
        // against its inputs (RECORDED_ELEMENTS.md).
        LiveVariant::Recorded(rec) => (
            rec.evaluate_with(precision, &resolver, &mut visiting),
            rec.fill.clone(),
            rec.stroke.clone(),
        ),
        // A generated element renders its concept's evaluated geometry, resolving
        // the concept through the resolver's registry (CONCEPTS.md 3b).
        LiveVariant::Generated(ge) => (
            ge.evaluate_with(precision, &resolver, &mut visiting),
            ge.fill.clone(),
            ge.stroke.clone(),
        ),
    }
}

/// The evaluated rings as ONE path -- the legacy trace, which opens a single
/// path and closes each ring into it, so a multi-ring result fills with the
/// non-zero rule as one shape rather than as N overlapping ones.
///
/// A ring of fewer than two points is skipped (it has no edge to trace);
/// `render.rs` skips the same ones with the same test.
fn live_rings_path(rings: &crate::algorithms::boolean::PolygonSet) -> Vec<PathCommand> {
    let mut path = Vec::new();
    for ring in rings {
        if ring.len() < 2 {
            continue;
        }
        path.push(PathCommand::MoveTo { x: ring[0].0, y: ring[0].1 });
        for &(x, y) in &ring[1..] {
            path.push(PathCommand::LineTo { x, y });
        }
        path.push(PathCommand::ClosePath);
    }
    path
}

// ---------------------------------------------------------------------------
// Outline mode (node 2 delta)
// ---------------------------------------------------------------------------

/// The stroke `render.rs::apply_outline_style` installs, as a `StrokeStyle`.
///
/// Every field is pinned there, and each one MATTERS because outline mode is a
/// REPLACEMENT: `set_line_width(1.0)`, `set_line_cap("butt")`,
/// `set_line_join("miter")`, `set_miter_limit(10.0)`, and — the easiest to
/// forget — `set_line_dash([])`, which DROPS the element's own dash pattern. An
/// outline that inherited the element's dash would render a dashed wireframe
/// for a dashed shape, which is a different picture rather than a missing one.
///
/// ⚠️ THE 1.0 IS IN DEVICE-INDEPENDENT DOCUMENT UNITS, exactly as production
/// writes it, and it is NOT counter-scaled here. `render.rs` counter-scales an
/// element's OWN stroke against the accumulated element transform; outline mode
/// sets its width AFTER that, on the raw context, so a scaled element gets a
/// scaled hairline in production too. Matching that is the point — a "fix" here
/// would be a divergence from the reference renderer, not an improvement.
fn outline_stroke_style() -> StrokeStyle {
    StrokeStyle {
        width: 1.0,
        cap: crate::painter::LineCap::Butt,
        join: crate::painter::LineJoin::Miter,
        miter: 10.0,
        dash: Vec::new(),
    }
}

/// One black hairline over `elem`'s own geometry, and NEITHER of its paints.
///
/// ⛔ THE SHAPE IS THE ELEMENT'S, THE PAINT IS NOT. Outline mode asks "where is
/// this element" and answers in a fixed style; it must therefore reach the same
/// geometry the normal arms do (rounded corners, ellipse arcs, winding-free
/// polylines) while ignoring fill, fill gradient, stroke colour, stroke width,
/// stroke opacity, dash and alignment.
///
/// `Text` / `TextPath` fall through silently, and that is not a gap left open
/// here: [`element_needs_legacy`] still routes both to legacy (text needs
/// shaping this seam has no vocabulary for), so this arm is unreachable for
/// them. Painting a bounding box instead would invent a picture production does
/// not draw.
///
/// ⭐ `Live` USED TO BE IN THAT SENTENCE, AND ROW CV TOOK IT OUT. The
/// justification was the router, and the router no longer routes it away -- so
/// a fall-through would now be a real hole, not an unreachable arm: an outlined
/// group holding a live child would drop the child rather than wireframe it.
/// `render.rs`'s Live arm branches on `outline` like every other arm does.
fn emit_outline_body(p: &mut dyn Painter, elem: &Element, eff: f64) {
    let brush = Brush::Solid(Color::rgb(0.0, 0.0, 0.0));
    let style = outline_stroke_style();
    match elem {
        Element::Line(e) => p.stroke_path(
            &[
                PathCommand::MoveTo { x: e.x1, y: e.y1 },
                PathCommand::LineTo { x: e.x2, y: e.y2 },
            ],
            &brush,
            &style,
            eff,
        ),
        Element::Rect(e) => {
            if e.rx > 0.0 || e.ry > 0.0 {
                let path = rounded_rect_path(e.x, e.y, e.width, e.height, e.rx, e.ry);
                p.stroke_path(&path, &brush, &style, eff);
            } else {
                let rect = Rect { x: e.x, y: e.y, w: e.width, h: e.height };
                // `stroke_rect`, not the path form: outline is always CENTER
                // aligned (it has no alignment of its own to honour), which is
                // the one case the normal Rect arm also lowers this way.
                p.stroke_rect(rect, &brush, &style, eff);
            }
        }
        Element::Ellipse(e) => {
            let arc = EllipseArc::ellipse(e.cx, e.cy, e.rx, e.ry);
            p.stroke_ellipse_arc(&arc, &brush, &style, eff);
        }
        Element::Polyline(e) => {
            if !e.points.is_empty() {
                p.stroke_path(&poly_path(&e.points, false), &brush, &style, eff);
            }
        }
        Element::Polygon(e) => {
            if !e.points.is_empty() {
                p.stroke_path(&poly_path(&e.points, true), &brush, &style, eff);
            }
        }
        // The element's own path commands, NOT an outline of its stroke: a
        // variable-width or brushed path outlines as its SPINE in production
        // too, because `apply_outline_style` runs before the width machinery.
        Element::Path(e) => p.stroke_path(&e.d, &brush, &style, eff),
        // Groups recurse in `emit_element_body` and never reach here.
        Element::Group(_) | Element::Layer(_) => {}
        // ⭐ ROW CV. The hairline traces the EVALUATED rings -- outline mode asks
        // "where is this element", and for a live element the answer is its
        // output, not its operands and not its bounds. Legacy reaches the same
        // picture from the other side: under `outline` its Live arm calls
        // `apply_outline_style` INSTEAD of the fill/stroke pair, leaves
        // `stroke_align` at its `Center` initialiser, and strokes the same
        // traced path. The element's own paint is dropped entirely, which is
        // why nothing here reads `live_paint`'s second and third members.
        Element::Live(v) => {
            let (rings, _, _) = live_paint(v);
            let path = live_rings_path(&rings);
            if !path.is_empty() {
                p.stroke_path(&path, &brush, &style, eff);
            }
        }
        Element::Text(_) | Element::TextPath(_) => {}
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
