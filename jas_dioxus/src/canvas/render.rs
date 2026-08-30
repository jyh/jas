//! Canvas2D rendering of document elements.
//!
//! Draws the document onto an HTML <canvas> via web_sys::CanvasRenderingContext2d.

use std::cell::RefCell;
// In scope so RenderResolver's `resolve` (paint inheritance lookup) is callable.
use crate::geometry::live::ElementResolver;

use wasm_bindgen::JsCast;
use web_sys::{CanvasRenderingContext2d, HtmlCanvasElement};

use crate::algorithms::calligraphic_outline::{calligraphic_outline, CalligraphicBrush};
use crate::algorithms::art_along_path::{art_along_path, ArtBrush};
use crate::algorithms::pattern_along_path::{pattern_along_path, PatternBrush};
use crate::algorithms::bristle_stroke::{bristle_stroke, BristleBrush};
use crate::document::artboard::{Artboard, ArtboardFill};
use crate::document::document::Document;
use crate::geometry::element::Visibility;
use crate::geometry::element::*;
use crate::geometry::measure::path_point_at_offset;
use crate::tools::tool::HANDLE_DRAW_SIZE;
// RAII balance for ctx.save()/restore() — see canvas::ctx_guard for the
// two usage laws and the contract tests.
use super::ctx_guard::CtxSaveGuard;

// ---------------------------------------------------------------------------
// Brush library lookup (thread-local, set for the duration of render())
// ---------------------------------------------------------------------------
//
// The Calligraphic outliner needs brush parameters keyed by the
// jas:stroke-brush "<library>/<brush>" slug carried on each PathElem.
// Threading brush_libraries through every canvas helper signature would
// be invasive in this 2000-line file, so we mirror the thread_local
// pattern used by `interpreter::doc_primitives` for Document.

thread_local! {
    static CURRENT_BRUSH_LIBS: RefCell<serde_json::Value> =
        RefCell::new(serde_json::Value::Null);
}

/// Install `libs` as the current render's brush library registry.
/// Returns a guard whose Drop restores the previous registry.
pub struct BrushLibsGuard {
    prior: serde_json::Value,
}

impl Drop for BrushLibsGuard {
    fn drop(&mut self) {
        let prior = std::mem::replace(&mut self.prior, serde_json::Value::Null);
        CURRENT_BRUSH_LIBS.with(|c| *c.borrow_mut() = prior);
    }
}

pub fn register_brush_libraries(libs: serde_json::Value) -> BrushLibsGuard {
    let prior = CURRENT_BRUSH_LIBS.with(|c| c.replace(libs));
    BrushLibsGuard { prior }
}

// Reference resolution (REFERENCE_GRAPH.md Phase 1b / Phase 4b): an
// id->element index. As of Phase 4b the index is a PERSISTENT map computed
// once and carried on the Model paired with the snapshot (so undo carries it
// in O(1) and paint never rebuilds it), rather than a fresh HashMap rebuilt
// each paint. Paint installs the Model's already-built index into a
// thread-local (an O(1) rpds clone) so the live render arms resolve by-id
// references without threading a resolver through every draw_element
// signature. The cycle-guard VisitSet stays a fresh local per top-level
// evaluate (passed to evaluate_with) — never thread state.
//
// The map values are bit-identical to the old rebuild (same walk, same
// first-occurrence-wins discipline, same sorted-symbols order), so resolve()
// results are unchanged — this is a pure Rust-only perf refactor.

// Phase 4b: the persistent `IdIndex` type and its pure builders
// (`rebuild_id_index` / `incremental_update_index`) moved to the CORE
// `document::id_index` module so the (also-core) `Model` no longer pulls in
// this web-gated module — keeping `--no-default-features` (the cross-language
// harness driver) compiling. They are re-exported here so existing
// `canvas::render::{IdIndex, rebuild_id_index, incremental_update_index}`
// references keep working. The render-scoped INSTALLATION below
// (`CURRENT_REF_INDEX`, `install_ref_index`, `RenderResolver`) stays here: it
// is paint-only.
pub use crate::document::id_index::{incremental_update_index, rebuild_id_index, IdIndex};

thread_local! {
    static CURRENT_REF_INDEX: RefCell<IdIndex> = RefCell::new(IdIndex::new());
}

/// Restores the prior index on drop, so nested renders nest safely.
pub struct RefIndexGuard {
    prior: IdIndex,
}
impl Drop for RefIndexGuard {
    fn drop(&mut self) {
        CURRENT_REF_INDEX.with(|c| *c.borrow_mut() = std::mem::take(&mut self.prior));
    }
}

/// Install an already-built `index` for this render and return a guard that
/// restores the prior index on drop (so nested renders nest safely). This is
/// the Phase-4b paint entry: the caller passes the Model's persistent index
/// (an O(1) rpds clone) — no per-paint rebuild.
pub fn install_ref_index(index: IdIndex) -> RefIndexGuard {
    let prior = CURRENT_REF_INDEX.with(|c| c.replace(index));
    RefIndexGuard { prior }
}

/// Build the index from `doc` and install it for this render, returning a
/// restore guard. Retained for tests that don't have a precomputed index
/// (the resolver/symbols fixtures); the hot paint path uses
/// [`install_ref_index`] with the Model's persistent index instead.
// Only referenced from the #[cfg(test)] resolver fixtures now that paint
// installs the Model's prebuilt index — keep it as the convenience
// build-and-install used by those tests.
#[allow(dead_code)]
pub fn register_ref_index(doc: &Document) -> RefIndexGuard {
    install_ref_index(rebuild_id_index(doc))
}

/// Zero-sized resolver reading the render-scoped index; passed to
/// `evaluate_with` so the live render arms resolve references.
struct RenderResolver;
impl crate::geometry::live::ElementResolver for RenderResolver {
    fn resolve(
        &self,
        id: &crate::geometry::live::ElementRef,
    ) -> Option<std::rc::Rc<Element>> {
        CURRENT_REF_INDEX.with(|c| c.borrow().get(&id.0).cloned())
    }

    /// Resolve a concept pack from the bundled workspace registry so a
    /// `Generated` instance renders its concept's geometry on canvas
    /// (CONCEPTS.md 3b). Shared with the hit-test resolver so paint and
    /// selection cannot disagree about a concept's geometry.
    fn resolve_concept(
        &self,
        concept_id: &str,
    ) -> Option<crate::geometry::live::ConceptDef> {
        crate::geometry::live::workspace_concept(concept_id)
    }
}

/// Look up a brush by its "<library>/<brush>" slug in the current
/// thread-local registry. Returns None if the slug is missing or
/// malformed, so the caller can fall back to the plain native stroke
/// render (null-on-missing per BRUSHES.md §Selection model).
fn lookup_brush(slug: &str) -> Option<serde_json::Value> {
    let sep = slug.find('/')?;
    let (lib_id, brush_slug) = slug.split_at(sep);
    let brush_slug = &brush_slug[1..]; // skip the '/'
    CURRENT_BRUSH_LIBS.with(|c| {
        let libs = c.borrow();
        let lib = libs.get(lib_id)?;
        let brushes = lib.get("brushes")?.as_array()?;
        brushes
            .iter()
            .find(|b| b.get("slug").and_then(|v| v.as_str()) == Some(brush_slug))
            .cloned()
    })
}

/// If the brush JSON describes a Calligraphic brush, extract its
/// angle / roundness / size into the native struct. Other brush types
/// return None in Phase 1 — the renderer falls back to plain stroke
/// (matches BRUSHES.md Phase 1 "Calligraphic only" scope).
fn calligraphic_from_json(brush: &serde_json::Value) -> Option<CalligraphicBrush> {
    if brush.get("type").and_then(|v| v.as_str()) != Some("calligraphic") {
        return None;
    }
    Some(CalligraphicBrush {
        angle: brush.get("angle").and_then(|v| v.as_f64()).unwrap_or(0.0),
        roundness: brush.get("roundness").and_then(|v| v.as_f64()).unwrap_or(100.0),
        size: brush.get("size").and_then(|v| v.as_f64()).unwrap_or(5.0),
    })
}

/// Draw `elem` as a brushed stroke: compute the Calligraphic outline
/// polygon and fill it with the element's stroke colour. Returns true
/// if the brushed render succeeded; false when the brush is missing or
/// not Calligraphic (the caller then falls back to the plain stroke
/// render).
fn draw_brushed_path(
    ctx: &CanvasRenderingContext2d,
    elem: &PathElem,
    outline: bool,
) -> bool {
    if outline {
        // Outline (wireframe) mode ignores brushes; caller handles.
        return false;
    }
    let slug = match elem.stroke_brush.as_deref() {
        Some(s) => s,
        None => return false,
    };
    let brush = match lookup_brush(slug) {
        Some(b) => b,
        None => return false, // null-on-missing fallback
    };
    let color = match elem.stroke.as_ref() {
        Some(s) => css_color(&s.color),
        None => "#000000".to_string(),
    };
    let stroke_weight = elem.stroke.as_ref().map(|s| s.width).unwrap_or(1.0);

    // Calligraphic: one variable-width outline polygon.
    if let Some(cal) = calligraphic_from_json(&brush) {
        let pts = calligraphic_outline(&elem.d, &cal);
        if pts.len() < 3 {
            return true; // degenerate — handled (emit nothing)
        }
        ctx.set_fill_style_str(&color);
        ctx.begin_path();
        ctx.move_to(pts[0].0, pts[0].1);
        for p in &pts[1..] {
            ctx.line_to(p.0, p.1);
        }
        ctx.close_path();
        ctx.fill();
        return true;
    }

    // Art: one artwork warped along the path; fill each warped polygon.
    if let Some(art) = art_from_json(&brush, stroke_weight) {
        let polys = art_along_path(&elem.d, &art);
        if polys.is_empty() {
            return true;
        }
        ctx.set_fill_style_str(&color);
        for poly in &polys {
            if poly.len() < 3 {
                continue;
            }
            ctx.begin_path();
            ctx.move_to(poly[0].0, poly[0].1);
            for p in &poly[1..] {
                ctx.line_to(p.0, p.1);
            }
            ctx.close_path();
            ctx.fill();
        }
        return true;
    }

    // Pattern: side tile repeated along the path; fill each warped tile.
    if let Some(pat) = pattern_from_json(&brush, stroke_weight) {
        let polys = pattern_along_path(&elem.d, &pat);
        if polys.is_empty() {
            return true;
        }
        ctx.set_fill_style_str(&color);
        for poly in &polys {
            if poly.len() < 3 {
                continue;
            }
            ctx.begin_path();
            ctx.move_to(poly[0].0, poly[0].1);
            for p in &poly[1..] {
                ctx.line_to(p.0, p.1);
            }
            ctx.close_path();
            ctx.fill();
        }
        return true;
    }

    // Bristle: N semi-transparent offset bristle lines stroked in the
    // stroke colour (per-bristle alpha, they overlap and build up).
    if let Some(br) = bristle_from_json(&brush, stroke_weight) {
        let lines = bristle_stroke(&elem.d, &br);
        if lines.is_empty() {
            return true;
        }
        let (r, g, b) = elem
            .stroke
            .as_ref()
            .map(|s| {
                let (rf, gf, bf, _) = s.color.to_rgba();
                ((rf * 255.0).round() as u8, (gf * 255.0).round() as u8, (bf * 255.0).round() as u8)
            })
            .unwrap_or((0, 0, 0));
        ctx.set_stroke_style_str(&format!("rgba({r},{g},{b},{})", br.alpha()));
        ctx.set_line_width(br.line_width());
        for line in &lines {
            if line.len() < 2 {
                continue;
            }
            ctx.begin_path();
            ctx.move_to(line[0].0, line[0].1);
            for p in &line[1..] {
                ctx.line_to(p.0, p.1);
            }
            ctx.stroke();
        }
        return true;
    }

    false // other brush types → plain stroke fallback
}

/// Build a `BristleBrush` from the library JSON. Shared with the
/// Brushes-panel `brush_preview` thumbnail.
pub(crate) fn bristle_from_json(brush: &serde_json::Value, stroke_weight: f64) -> Option<BristleBrush> {
    if brush.get("type").and_then(|v| v.as_str()) != Some("bristle") {
        return None;
    }
    Some(BristleBrush {
        size: brush.get("size").and_then(|v| v.as_f64()).unwrap_or(3.0),
        density: brush.get("density").and_then(|v| v.as_f64()).unwrap_or(50.0),
        thickness: brush.get("thickness").and_then(|v| v.as_f64()).unwrap_or(30.0),
        opacity: brush.get("opacity").and_then(|v| v.as_f64()).unwrap_or(30.0),
        stroke_weight,
    })
}

/// Parse a `{ width, height, polygons: [[[x,y],...],...] }` object into a
/// (width, height, polygons) tuple. Shared by the art / pattern parsers.
pub(crate) fn parse_inline_artwork(
    aw: &serde_json::Value,
) -> Option<(f64, f64, Vec<Vec<(f64, f64)>>)> {
    let width = aw.get("width").and_then(|v| v.as_f64())?;
    let height = aw.get("height").and_then(|v| v.as_f64())?;
    let polys = aw.get("polygons").and_then(|v| v.as_array())?;
    let polygons: Vec<Vec<(f64, f64)>> = polys
        .iter()
        .filter_map(|p| {
            p.as_array().map(|pts| {
                pts.iter()
                    .filter_map(|pt| {
                        let a = pt.as_array()?;
                        Some((a.first()?.as_f64()?, a.get(1)?.as_f64()?))
                    })
                    .collect()
            })
        })
        .collect();
    Some((width, height, polygons))
}

/// Build a `PatternBrush` from the library JSON. Side tile stored inline as
/// `tiles: { side: { width, height, polygons } }` (Phase 1: side only).
/// Shared with the Brushes-panel `brush_preview` thumbnail.
pub(crate) fn pattern_from_json(brush: &serde_json::Value, stroke_weight: f64) -> Option<PatternBrush> {
    if brush.get("type").and_then(|v| v.as_str()) != Some("pattern") {
        return None;
    }
    let side = brush.get("tiles")?.get("side")?;
    let (width, height, polygons) = parse_inline_artwork(side)?;
    Some(PatternBrush {
        tile_width: width,
        tile_height: height,
        side: polygons,
        scale: brush.get("scale").and_then(|v| v.as_f64()).unwrap_or(100.0),
        spacing: brush.get("spacing").and_then(|v| v.as_f64()).unwrap_or(0.0),
        flip_across: brush.get("flip_across").and_then(|v| v.as_bool()).unwrap_or(false),
        flip_along: brush.get("flip_along").and_then(|v| v.as_bool()).unwrap_or(false),
        stroke_weight,
    })
}

/// Build an `ArtBrush` from the library JSON. Artwork is stored inline as
/// `artwork: { width, height, polygons: [[[x,y], ...], ...] }` (BRUSHES.md
/// §Brush libraries; inline polygon form for Phase 1). Shared with the
/// Brushes-panel `brush_preview` thumbnail.
pub(crate) fn art_from_json(brush: &serde_json::Value, stroke_weight: f64) -> Option<ArtBrush> {
    if brush.get("type").and_then(|v| v.as_str()) != Some("art") {
        return None;
    }
    let aw = brush.get("artwork")?;
    let width = aw.get("width").and_then(|v| v.as_f64())?;
    let height = aw.get("height").and_then(|v| v.as_f64())?;
    let polys = aw.get("polygons").and_then(|v| v.as_array())?;
    let artwork: Vec<Vec<(f64, f64)>> = polys
        .iter()
        .filter_map(|p| {
            p.as_array().map(|pts| {
                pts.iter()
                    .filter_map(|pt| {
                        let a = pt.as_array()?;
                        Some((a.first()?.as_f64()?, a.get(1)?.as_f64()?))
                    })
                    .collect()
            })
        })
        .collect();
    Some(ArtBrush {
        artwork_width: width,
        artwork_height: height,
        artwork,
        scale: brush.get("scale").and_then(|v| v.as_f64()).unwrap_or(100.0),
        flip_across: brush.get("flip_across").and_then(|v| v.as_bool()).unwrap_or(false),
        flip_along: brush.get("flip_along").and_then(|v| v.as_bool()).unwrap_or(false),
        stroke_weight,
    })
}

// ---------------------------------------------------------------------------
// Color conversion
// ---------------------------------------------------------------------------

fn css_color(c: &Color) -> String {
    let (r, g, b, a) = c.to_rgba();
    if a >= 1.0 {
        format!(
            "rgb({},{},{})",
            (r * 255.0) as u8,
            (g * 255.0) as u8,
            (b * 255.0) as u8,
        )
    } else {
        format!(
            "rgba({},{},{},{})",
            (r * 255.0) as u8,
            (g * 255.0) as u8,
            (b * 255.0) as u8,
            a,
        )
    }
}

/// Map a BlendMode to the Canvas2D `globalCompositeOperation` string.
/// Canvas2D natively supports all 16 separable / non-separable blend modes
/// used by the Opacity panel; Normal maps to the default `source-over`.
pub(crate) fn blend_mode_css(mode: BlendMode) -> &'static str {
    match mode {
        BlendMode::Normal      => "source-over",
        BlendMode::Darken      => "darken",
        BlendMode::Multiply    => "multiply",
        BlendMode::ColorBurn   => "color-burn",
        BlendMode::Lighten     => "lighten",
        BlendMode::Screen      => "screen",
        BlendMode::ColorDodge  => "color-dodge",
        BlendMode::Overlay     => "overlay",
        BlendMode::SoftLight   => "soft-light",
        BlendMode::HardLight   => "hard-light",
        BlendMode::Difference  => "difference",
        BlendMode::Exclusion   => "exclusion",
        BlendMode::Hue         => "hue",
        BlendMode::Saturation  => "saturation",
        BlendMode::Color       => "color",
        BlendMode::Luminosity  => "luminosity",
    }
}

/// Build a CanvasGradient from a `Gradient` and the element's bounding box.
/// Returns None if the gradient is freeform (rendering deferred to a later
/// phase) or has fewer than 2 stops.
fn make_canvas_gradient(
    ctx: &CanvasRenderingContext2d,
    g: &Gradient,
    bx: f64, by: f64, bw: f64, bh: f64,
) -> Option<web_sys::CanvasGradient> {
    if g.stops.len() < 2 { return None; }
    let cg = match g.gtype {
        GradientType::Linear => {
            // Angle convention: 0° = left-to-right; positive rotates CCW.
            // Endpoints lie on the bbox boundary aligned with the angle.
            let cx = bx + bw / 2.0;
            let cy = by + bh / 2.0;
            let rad = g.angle.to_radians();
            let half_diag = (bw * bw + bh * bh).sqrt() / 2.0;
            let dx = rad.cos() * half_diag;
            let dy = -rad.sin() * half_diag; // canvas y is down
            ctx.create_linear_gradient(cx - dx, cy - dy, cx + dx, cy + dy)
        }
        GradientType::Radial => {
            let cx = bx + bw / 2.0;
            let cy = by + bh / 2.0;
            let r = (bw.max(bh) / 2.0) * (g.aspect_ratio / 100.0).max(0.01);
            ctx.create_radial_gradient(cx, cy, 0.0, cx, cy, r).ok()?
        }
        GradientType::Freeform => return None,
    };
    for stop in &g.stops {
        let mut c = stop.color.with_alpha(stop.opacity / 100.0);
        // The opacity field is applied via alpha so a per-stop opacity of
        // 50 becomes a stop with an rgba color at 50% alpha.
        if stop.opacity == 100.0 {
            c = stop.color;
        }
        let _ = cg.add_color_stop((stop.location / 100.0) as f32, &css_color(&c));
    }
    Some(cg)
}

fn poly_bbox(pts: &[(f64, f64)]) -> (f64, f64, f64, f64) {
    if pts.is_empty() { return (0.0, 0.0, 0.0, 0.0); }
    let (mut x_min, mut y_min) = pts[0];
    let (mut x_max, mut y_max) = pts[0];
    for &(x, y) in &pts[1..] {
        if x < x_min { x_min = x; } if x > x_max { x_max = x; }
        if y < y_min { y_min = y; } if y > y_max { y_max = y; }
    }
    (x_min, y_min, x_max - x_min, y_max - y_min)
}

fn apply_fill(
    ctx: &CanvasRenderingContext2d, fill: Option<&Fill>,
    fill_gradient: Option<&Gradient>, bbox: (f64, f64, f64, f64),
) -> f64 {
    if let Some(g) = fill_gradient {
        let (bx, by, bw, bh) = bbox;
        if let Some(cg) = make_canvas_gradient(ctx, g, bx, by, bw, bh) {
            ctx.set_fill_style_canvas_gradient(&cg);
            return fill.map(|f| f.opacity).unwrap_or(1.0);
        }
    }
    match fill {
        Some(f) => {
            ctx.set_fill_style_str(&css_color(&f.color));
            f.opacity
        }
        None => {
            ctx.set_fill_style_str("transparent");
            1.0
        }
    }
}

/// The geometric-mean scale of a 2x3 affine — `sqrt(|det|)` of the linear
/// part (`a*d - b*c`). 1.0 for `None` or a degenerate (det 0) transform.
/// The per-transform building block of the selection-outline counter-scale
/// and the element-stroke counter-scale (see `accumulate_element_scale`).
fn transform_scale_factor(transform: Option<&Transform>) -> f64 {
    match transform {
        Some(t) => {
            let det = (t.a * t.d - t.b * t.c).abs();
            if det > 0.0 { det.sqrt() } else { 1.0 }
        }
        None => 1.0,
    }
}

/// Return `(element, accumulated_scale)` for rendering this element's body.
///
/// `accumulated_scale` = `element_scale` times this element's own transform
/// scale (`transform_scale_factor`). When there is an actual scale (> 1e-6 and
/// != 1.0) and the element carries a stroke, the returned element is a COPY
/// whose `stroke.width` is divided by that scale; otherwise the element is
/// returned unchanged.
///
/// An element's own STROKE is drawn UNDER the element transform (the matrix is
/// already on the painter), so the matrix would scale the stroke width — on
/// top of any `scale_strokes` bake at apply time — a double-scale. Rewriting
/// the stroke width at the SOURCE (so the copy carries the divided width)
/// cancels the element transform's scaling for EVERY stroke.width reader: the
/// pen line width AND the Line arrowhead SETBACK (which shortens the line by an
/// amount derived from `stroke.width`). The stroke renders at its nominal
/// (still zoom-scaled) width. Uses the ELEMENT transform chain ONLY (never the
/// view/zoom transform), so the stroke still scales with zoom — matching the
/// selection-outline counter-scale. The accumulated scale is threaded to
/// children so a stroked shape inside a transformed group is counter-scaled by
/// the full ancestor chain. Mirrors the Python `_counter_scaled_element`
/// (8ac2f4d1) and OCaml `counter_scaled_element` (60ed68fb).
fn counter_scaled_element(elem: &Element, element_scale: f64) -> (Element, f64) {
    let elem_scale = element_scale * transform_scale_factor(elem.transform());
    if elem_scale > 1e-6 && (elem_scale - 1.0).abs() > 1e-9 {
        // Counter-scale the stroke width (if any) ...
        let mut out = match elem.stroke() {
            Some(s) => {
                let mut scaled = s.clone();
                scaled.width = s.width / elem_scale;
                with_stroke(elem, Some(scaled))
            }
            None => elem.clone(),
        };
        // ... and a rounded rect's corner radii, so the corner stays a fixed
        // size under a scale (scale_corners defaults OFF). When it was ON the
        // apply baked rx,ry *= factor, so the net rendered radius scales once.
        if let Element::Rect(r) = &mut out {
            if r.rx != 0.0 || r.ry != 0.0 {
                r.rx /= elem_scale;
                r.ry /= elem_scale;
            }
        }
        return (out, elem_scale);
    }
    (elem.clone(), elem_scale)
}

/// Return value from apply_stroke: (opacity, alignment).
fn apply_stroke(
    ctx: &CanvasRenderingContext2d,
    stroke: Option<&Stroke>,
) -> (f64, StrokeAlign) {
    apply_stroke_with_gradient(ctx, stroke, None, (0.0, 0.0, 0.0, 0.0))
}

/// Phase 8: gradient-aware stroke. When `stroke_gradient` is set and
/// renderable, sets the context stroke style to a CanvasGradient
/// (within-stroke sub-mode only; along / across remain
/// `pending_renderer` per GRADIENT.md §Stroke sub-modes).
fn apply_stroke_with_gradient(
    ctx: &CanvasRenderingContext2d,
    stroke: Option<&Stroke>,
    stroke_gradient: Option<&Gradient>,
    bbox: (f64, f64, f64, f64),
) -> (f64, StrokeAlign) {
    match stroke {
        Some(s) => {
            if let Some(g) = stroke_gradient {
                let (bx, by, bw, bh) = bbox;
                if let Some(cg) = make_canvas_gradient(ctx, g, bx, by, bw, bh) {
                    ctx.set_stroke_style_canvas_gradient(&cg);
                } else {
                    ctx.set_stroke_style_str(&css_color(&s.color));
                }
            } else {
                ctx.set_stroke_style_str(&css_color(&s.color));
            }
            // Inside/outside use 2x width; the clip removes the unwanted half.
            // The element-transform counter-scale is already baked into
            // `s.width` here: `counter_scaled_element` rebinds the element to a
            // copy whose stroke width is divided by the accumulated
            // element-transform scale at body entry, so the element transform
            // (already on the painter) does NOT thicken the stroke — it renders
            // at the nominal, zoom-scaled width, cancelling the matrix's stroke
            // scaling and the scale_strokes double-scale.
            let effective_width = match s.align {
                StrokeAlign::Center => s.width,
                StrokeAlign::Inside | StrokeAlign::Outside => s.width * 2.0,
            };
            ctx.set_line_width(effective_width);
            ctx.set_line_cap(match s.linecap {
                LineCap::Butt => "butt",
                LineCap::Round => "round",
                LineCap::Square => "square",
            });
            ctx.set_line_join(match s.linejoin {
                LineJoin::Miter => "miter",
                LineJoin::Round => "round",
                LineJoin::Bevel => "bevel",
            });
            ctx.set_miter_limit(s.miter_limit);
            let da = s.dash_array();
            // When dash_align_anchors is on, the renderer expands the
            // dashed stroke into solid sub-paths via DashRenderer and
            // draws each as a solid stroke — so the platform's dash
            // attribute must be empty here. See DASH_ALIGN.md
            // §Algorithm. Per-shape callers branch on
            // s.dash_align_anchors to choose the dasher path.
            if !da.is_empty() && !s.dash_align_anchors {
                let js_array = js_sys::Array::new();
                for &v in da {
                    js_array.push(&wasm_bindgen::JsValue::from_f64(v));
                }
                ctx.set_line_dash(&js_array).ok();
            } else {
                ctx.set_line_dash(&js_sys::Array::new()).ok();
            }
            (s.opacity, s.align)
        }
        None => {
            ctx.set_stroke_style_str("transparent");
            ctx.set_line_width(0.0);
            (1.0, StrokeAlign::Center)
        }
    }
}

/// Stroke the current path with alignment clipping.
/// The current path must already be traced on the context.
/// For Inside, clips to the path fill area, strokes at 2x width (set by apply_stroke).
/// For Outside, clips to the inverse of the path (evenodd with large rect), strokes at 2x width.
/// For Center, just strokes normally.
fn stroke_aligned(ctx: &CanvasRenderingContext2d, align: StrokeAlign) {
    match align {
        StrokeAlign::Center => {
            ctx.stroke();
        }
        StrokeAlign::Inside => {
            // The current path is still on the context. Clip to it,
            // then stroke — only the inner half of the 2x-width stroke is visible.
            // The clip is scoped to this arm by the guard (see CtxSaveGuard).
            let _ctx_guard = CtxSaveGuard::new(ctx);
            ctx.clip();
            ctx.stroke();
        }
        StrokeAlign::Outside => {
            // The current path is still on the context. Add a huge rect
            // to the existing path (rect() doesn't clear it), then clip
            // with evenodd — this clips to everything OUTSIDE the shape.
            // Guarded: the reflection call below can panic on an exotic
            // context, and Drop still pops the clip on that path.
            let _ctx_guard = CtxSaveGuard::new(ctx);
            ctx.rect(-1e6, -1e6, 2e6, 2e6);
            // Call clip("evenodd") via js_sys since web-sys may not expose the overload
            let _ = js_sys::Reflect::apply(
                &js_sys::Function::from(wasm_bindgen::JsValue::from(
                    js_sys::Reflect::get(ctx, &wasm_bindgen::JsValue::from_str("clip")).unwrap()
                )),
                ctx,
                &js_sys::Array::of1(&wasm_bindgen::JsValue::from_str("evenodd")),
            );
            ctx.stroke();
        }
    }
}

fn apply_transform(ctx: &CanvasRenderingContext2d, transform: Option<&Transform>) {
    if let Some(t) = transform {
        ctx.transform(t.a, t.b, t.c, t.d, t.e, t.f).ok();
    }
}

// ---------------------------------------------------------------------------
// Build path commands into canvas path
// ---------------------------------------------------------------------------

pub(crate) fn build_path(ctx: &CanvasRenderingContext2d, cmds: &[PathCommand]) {
    for cmd in cmds {
        match cmd {
            PathCommand::MoveTo { x, y } => ctx.move_to(*x, *y),
            PathCommand::LineTo { x, y } => ctx.line_to(*x, *y),
            PathCommand::CurveTo {
                x1, y1, x2, y2, x, y,
            } => ctx.bezier_curve_to(*x1, *y1, *x2, *y2, *x, *y),
            PathCommand::QuadTo { x1, y1, x, y } => {
                ctx.quadratic_curve_to(*x1, *y1, *x, *y)
            }
            PathCommand::ClosePath => ctx.close_path(),
            // Smooth curves and arcs: approximate as line to endpoint
            PathCommand::SmoothCurveTo { x, y, .. }
            | PathCommand::SmoothQuadTo { x, y }
            | PathCommand::ArcTo { x, y, .. } => ctx.line_to(*x, *y),
        }
    }
}

// ---------------------------------------------------------------------------
// Draw a single element
// ---------------------------------------------------------------------------

/// Configure `ctx` for an outline-mode draw of a shape: no fill, a
/// thin black stroke. The spec says "stroke of size 0"; in practice
/// a canvas stroke width of 0 renders nothing, so we use the minimum
/// visible width (1 pixel). This is the mode used for every non-Text
/// element when its effective visibility is [`Visibility::Outline`].
fn apply_outline_style(ctx: &CanvasRenderingContext2d) {
    ctx.set_stroke_style_str("rgb(0,0,0)");
    ctx.set_fill_style_str("transparent");
    ctx.set_line_width(1.0);
    ctx.set_line_cap("butt");
    ctx.set_line_join("miter");
    ctx.set_line_dash(&wasm_bindgen::JsValue::from(js_sys::Array::new())).ok();
    ctx.set_miter_limit(10.0);
}

fn draw_element(
    ctx: &CanvasRenderingContext2d,
    elem: &Element,
    ancestor_vis: Visibility,
    precision: f64,
) {
    // Top-level / subtree entry: the accumulated element-transform scale
    // starts at 1.0 (the identity). It accumulates down the Group/Layer
    // recursion in draw_element_body.
    draw_element_scaled(ctx, elem, ancestor_vis, precision, 1.0);
}

/// As [draw_element], but carrying the accumulated element-transform scale
/// from the ancestor chain (see [accumulate_element_scale]). The public
/// [draw_element] seeds this at 1.0.
fn draw_element_scaled(
    ctx: &CanvasRenderingContext2d,
    elem: &Element,
    ancestor_vis: Visibility,
    precision: f64,
    element_scale: f64,
) {
    // Opacity mask: when an element carries an active mask,
    // redirect rendering through the mask composite path. The plan
    // encodes which of the three supported composite strategies to
    // use. OPACITY.md §Rendering.
    if let Some(mask) = elem.common().mask.as_deref() {
        if let Some(plan) = mask_plan(mask) {
            // PH4 — THE PRODUCTION CONVERSION. A masked element whose whole
            // subtree is expressible on the seam takes the ratified A6 element
            // bracket; everything else keeps the legacy composite below,
            // unchanged. See [draw_masked_element_through_the_seam] for the
            // four conditions and for what changes on screen when it fires.
            if draw_masked_element_through_the_seam(ctx, elem, ancestor_vis, element_scale) {
                return;
            }
            draw_element_with_mask(ctx, elem, mask, plan, ancestor_vis, precision, element_scale);
            return;
        }
    }
    draw_element_body(ctx, elem, ancestor_vis, precision, element_scale);
}

/// Would production's `counter_scaled_element` change anything the seam would
/// not? `acc` is the accumulated element-transform scale arriving at `elem`.
///
/// ⛔ THIS IS A DIVERGENCE GUARD, NOT A CAPABILITY QUESTION, which is why it
/// lives here and not in the router. Production counter-scales a stroke width
/// (and a rounded rect's corner radii) by the accumulated ELEMENT-transform
/// scale at every level, so a stroke renders at its nominal width under a
/// scaling transform. The `Painter` seam carries no such notion: it paints the
/// width it is handed. The leaf routes production already takes are safe
/// because they convert a leaf paint AFTER `counter_scaled_element` has rebound
/// the element; the A6 bracket enters BEFORE that and swallows a whole subtree,
/// so it must ask.
///
/// The scale test matches [counter_scaled_element]'s own condition exactly,
/// rather than approximating it — two spellings of one threshold is how the
/// guard and the thing it guards drift apart.
fn subtree_would_be_counter_scaled(elem: &Element, acc: f64) -> bool {
    let s = acc * transform_scale_factor(elem.transform());
    let scaled = s > 1e-6 && (s - 1.0).abs() > 1e-9;
    if scaled
        && (elem.stroke().is_some()
            || matches!(elem, Element::Rect(r) if r.rx != 0.0 || r.ry != 0.0))
    {
        return true;
    }
    // The mask artwork restarts the accumulation at 1.0 — `draw_element_with_mask`
    // renders the subtree through `draw_element`, whose public entry seeds the
    // scale at the identity. Ported, not re-derived.
    if let Some(m) = elem.common().mask.as_deref().filter(|m| !m.disabled) {
        if subtree_would_be_counter_scaled(&m.subtree, 1.0) {
            return true;
        }
    }
    if let Some(children) = elem.children() {
        if children.iter().any(|c| subtree_would_be_counter_scaled(c, s)) {
            return true;
        }
    }
    false
}

/// PH4 — render `elem` through the ratified A6 element bracket on the `Painter`
/// seam. Returns `false` having painted NOTHING when any condition fails, so
/// the caller falls back to the unchanged legacy composite.
///
/// # ⚠️ WHAT CHANGES ON SCREEN WHEN THIS FIRES — the announcement, in the code
///
/// This is A6 §6.2, and it is a ratified behaviour change for shipped documents
/// (Captain, 2026-08-30) rather than a refactor. It is NOT the `own²` defect —
/// that was D-α, repaired in this file on 2026-08-24 (`mask_blit_alpha`), and a
/// masked element already renders at `ancestors × own` here. What changes is
/// WHICH FACTOR IS ISOLATED:
///
/// | | legacy composite | A6 bracket |
/// |---|---|---|
/// | the element's OWN opacity | multiplied into every body primitive — overlaps inside the element COMPOUND | spent ONCE at the layer composite |
/// | the ANCESTOR group product | applied once, to the finished scratch | multiplied into every body primitive |
///
/// Production has these exactly the wrong way round. The contract pins group
/// alpha as NON-isolated (`painter/mod.rs`: each open group's alpha multiplies
/// into all descendants per-primitive) and A6 makes the masked element an
/// ISOLATED layer carrying its own opacity. For a single-primitive body the two
/// agree at `ancestors × own`, which is why this went unseen; they diverge, in
/// both directions, as soon as the masked element's body overlaps itself.
///
/// # The four conditions, each a different kind of refusal
///
/// 1. **`ancestor_vis` must be `Preview`.** The seam has no outline lowering and
///    no invisible cap; both are inherited state this function cannot see from
///    the element alone. (An element's OWN outline mode is the router's job —
///    see `element_needs_legacy`.)
/// 2. **The whole subtree must convert on this backend**
///    ([`subtree_needs_legacy`]) — body AND mask artwork. A legacy-only
///    descendant is DROPPED by `emit_element`, and legacy-only mask artwork
///    gives `M = 0`, which deletes the element.
/// 3. **Nothing in the subtree may be counter-scaled**
///    ([`subtree_would_be_counter_scaled`]).
/// 4. **The context's world transform must be readable.** A fresh layer surface
///    starts at identity; without the frame it opens at the wrong origin. The
///    read is this file's existing `read_ctx_transform`, the same one the legacy
///    composite uses, and it crosses to the painter as an explicit parameter.
///
/// ⛔ NO `cfg(feature = "web")` HERE, DELIBERATELY. The first cut carried one,
/// plus a `cfg(not(web))` stub returning `false` — a whole second arm that
/// cannot be reached, because `canvas` is itself `#[cfg(feature = "web")]` at
/// `lib.rs`. An unreachable arm wearing the signature of a live one is worse
/// than none: it reads as a supported configuration nobody has ever run.
fn draw_masked_element_through_the_seam(
    ctx: &CanvasRenderingContext2d,
    elem: &Element,
    ancestor_vis: Visibility,
    element_scale: f64,
) -> bool {
    use crate::painter::capability::Caps;
    use crate::painter::Painter as _;

    if ancestor_vis != Visibility::Preview {
        return false;
    }
    if subtree_would_be_counter_scaled(elem, element_scale) {
        return false;
    }
    let Some((a, b, c, d, e, f)) = read_ctx_transform(ctx) else {
        return false;
    };
    // Constructing a painter allocates nothing — a layer surface is created at
    // the first `push_isolated_layer` — so it is safe to build one just to ask
    // it what it can do, and every DECLINE below still leaves the context
    // untouched. That ordering is deliberate: the guard is taken only once the
    // answer is yes, so a masked element that stays legacy costs no save/restore
    // per frame.
    let mut painter = crate::painter::canvas2d::Canvas2dPainter::at_frame(
        ctx,
        Transform { a, b, c, d, e, f },
    );
    if crate::painter::element_render::subtree_needs_legacy(elem, Caps::of(&painter)) {
        return false;
    }
    // The ancestor alpha product, read the same way every other path here reads
    // it — off the context, before anything touches it.
    let incoming_alpha = ctx.global_alpha();
    // ⛔ GUARDED. The painter leaves the base context's alpha and composite
    // operation at values of its own choosing after a layer composite; the
    // guard puts the caller's state back on every exit, so a converted element
    // cannot change what its SIBLINGS render as.
    let _ctx_guard = CtxSaveGuard::new(ctx);
    crate::painter::element_render::emit_element(&mut painter, elem, incoming_alpha);
    true
}


// ---------------------------------------------------------------------------
// Opacity-mask compositing (OPACITY.md §Rendering)
// ---------------------------------------------------------------------------

/// How the mask subtree's rendered alpha is applied to the element.
/// Selected by [mask_plan] from the mask's ``clip`` and ``invert``
/// fields; consumed by [draw_element_with_mask].
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum MaskPlan {
    /// Element clipped to the mask shape. ``destination-in`` applied
    /// on the full offscreen canvas. `clip: true, invert: false`.
    ClipIn,
    /// Element clipped to the *inverse* of the mask shape.
    /// ``destination-out`` on the full offscreen canvas. Covers
    /// both `clip: true, invert: true` and — for alpha-based masks
    /// — `clip: false, invert: true`, which collapse to the same
    /// output (`E * (1 - M)` everywhere) since the mask's
    /// "outside" region contributes zero alpha either way.
    ClipOut,
    /// `clip: false, invert: false`: element stays at full alpha
    /// outside the mask subtree's bounding box; ``destination-in``
    /// with the mask applies only inside the bbox via a clip path.
    /// OPACITY.md §Rendering.
    RevealOutsideBbox,
}

/// Pick a [MaskPlan] for the mask, or ``None`` when the mask is
/// inactive (``disabled: true``). The plan encodes how
/// [draw_element_with_mask] should composite the mask subtree
/// against the element body.
fn mask_plan(mask: &Mask) -> Option<MaskPlan> {
    if mask.disabled {
        return None;
    }
    // ⛔ ONE TRUTH TABLE, AND IT IS NOT THIS ONE. The (clip, invert) lowering
    // moved to `painter::mask_from_flags` because it produces a SEAM type and
    // A6 §4 puts it at build time. This site now DERIVES its plan from that
    // single source instead of restating the table -- two copies of a truth
    // table is the shape this repo has already been bitten by twice (the CI
    // range guard, and the 08/25 force-push hardening that landed in one of two
    // files). The bbox is irrelevant to the choice, so a zero rect is passed
    // and discarded; only the VARIANT is read.
    let zero = crate::painter::Rect { x: 0.0, y: 0.0, w: 0.0, h: 0.0 };
    Some(match crate::painter::mask_from_flags(mask.clip, mask.invert, zero) {
        crate::painter::Mask::LuminanceClipIn => MaskPlan::ClipIn,
        crate::painter::Mask::AlphaClipOut => MaskPlan::ClipOut,
        crate::painter::Mask::AlphaRevealOutsideBbox { .. } => MaskPlan::RevealOutsideBbox,
    })
}

/// The alpha the masked element's composited scratch is blitted at.
///
/// THE MULTIPLICATIVE LAW — `painter/mod.rs:62-64` (effective alpha = product
/// of open group alphas x paint alpha), `OPACITY.md`, and this file's own
/// unmasked path (`base_alpha = parent_alpha * elem.opacity()`, :1205):
/// **each factor applies EXACTLY ONCE.**
///
/// The body pass already multiplied `own_opacity` into every primitive on the
/// scratch (it runs with the scratch ctx's `parent_alpha` = 1.0), so the blit
/// contributes the INHERITED ancestor-group product and must NOT re-apply
/// `own_opacity`. Re-applying it squares the element's own alpha, and because
/// `set_global_alpha` REPLACES the context's alpha rather than multiplying
/// into it, it also discards every ancestor group's contribution.
///
/// `own_opacity` is taken deliberately and deliberately unused: it is the
/// factor a future edit is most likely to re-introduce here, and naming it
/// makes that edit visible to `mask_blit_alpha_is_independent_of_own_opacity`.
fn mask_blit_alpha(parent_alpha: f64, own_opacity: f64) -> f64 {
    let _ = own_opacity;
    parent_alpha
}

/// Return the transform that should be applied when rendering the
/// mask's subtree on top of the ancestor coord system. Track C
/// phase 3, OPACITY.md §Document model:
///
/// - ``linked: true``  — mask inherits the element's transform
///   (mask follows the element).
/// - ``linked: false`` — mask uses ``unlink_transform`` (the
///   element's transform captured at unlink time, frozen so the
///   mask stays fixed under subsequent element edits).
fn effective_mask_transform<'a>(
    mask: &'a Mask,
    elem: &'a Element,
) -> Option<&'a Transform> {
    if mask.linked {
        elem.transform()
    } else {
        mask.unlink_transform.as_ref()
    }
}

thread_local! {
    /// Reusable offscreen canvas for opacity-mask compositing.
    /// Created lazily on first use and resized to match the main
    /// canvas when the dimensions change. Kept as a module-level
    /// scratch buffer to avoid allocating a new DOM canvas per
    /// masked element per frame.
    static MASK_CANVAS: RefCell<Vec<HtmlCanvasElement>> = const { RefCell::new(Vec::new()) };
    /// Second scratch canvas, used to render the mask subtree in
    /// isolation before its alpha is promoted to luminance (see
    /// [promote_mask_to_luminance]). Only populated when the
    /// ClipIn path enters the luminance branch.
    static MASK_LUMA_CANVAS: RefCell<Vec<HtmlCanvasElement>> = const { RefCell::new(Vec::new()) };
}

/// Read the six-component current transform from a Canvas2D context.
///
/// ⛔⛔ `currentTransform` DOES NOT EXIST IN CHROME, AND THAT IS NOT A
/// HYPOTHETICAL — measured 2026-08-30 in headless Chrome 151 by
/// `ph4_conversion_tests::currentTransform`-family probes: the property reads
/// `undefined`, this function returned `None`, and the masked composite below
/// therefore left its scratch at the IDENTITY while the main context carried
/// the view transform. A masked element under a `+8` view translate landed at
/// device `x = 2` instead of `x = 10`. **Every masked element in the shipped
/// browser app was drawn at the wrong place whenever the view was panned or
/// zoomed**, silently, because the caller's `if let Some(..)` simply did not
/// fire and this docstring called that "a reasonable degradation".
///
/// ⇒ `getTransform()` IS ASKED FIRST — the standard method Chrome implements,
/// returning a `DOMMatrix` with the same `a`..`f` fields. `currentTransform` is
/// kept as the fallback because it is what Firefox exposes and what this
/// function was written against. Both are reached by reflection for the same
/// reason as before: web-sys 0.3 binds neither under the features enabled here.
///
/// Returns `None` only when NEITHER is available, which now really does mean
/// "no transform information exists" rather than "you asked the wrong browser".
fn read_ctx_transform(
    ctx: &CanvasRenderingContext2d,
) -> Option<(f64, f64, f64, f64, f64, f64)> {
    let t = get_transform_object(ctx)?;
    let a = js_sys::Reflect::get(&t, &wasm_bindgen::JsValue::from_str("a")).ok()?.as_f64()?;
    let b = js_sys::Reflect::get(&t, &wasm_bindgen::JsValue::from_str("b")).ok()?.as_f64()?;
    let c = js_sys::Reflect::get(&t, &wasm_bindgen::JsValue::from_str("c")).ok()?.as_f64()?;
    let d = js_sys::Reflect::get(&t, &wasm_bindgen::JsValue::from_str("d")).ok()?.as_f64()?;
    let e = js_sys::Reflect::get(&t, &wasm_bindgen::JsValue::from_str("e")).ok()?.as_f64()?;
    let f = js_sys::Reflect::get(&t, &wasm_bindgen::JsValue::from_str("f")).ok()?.as_f64()?;
    Some((a, b, c, d, e, f))
}

/// The matrix-like object carrying the context's current transform, from
/// whichever of the two surfaces this browser has. See [read_ctx_transform] for
/// why the order matters.
fn get_transform_object(ctx: &CanvasRenderingContext2d) -> Option<wasm_bindgen::JsValue> {
    let key = wasm_bindgen::JsValue::from_str("getTransform");
    if let Ok(m) = js_sys::Reflect::get(ctx, &key) {
        if let Ok(func) = m.dyn_into::<js_sys::Function>() {
            if let Ok(v) = func.call0(ctx) {
                if !v.is_undefined() && !v.is_null() {
                    return Some(v);
                }
            }
        }
    }
    let v = js_sys::Reflect::get(
        ctx,
        &wasm_bindgen::JsValue::from_str("currentTransform"),
    ).ok()?;
    if v.is_undefined() || v.is_null() {
        return None;
    }
    Some(v)
}

/// Obtain (or lazily create) the scratch mask canvas, resized to
/// ``w x h``. Returns the canvas together with its 2D context.
/// Returns ``None`` if the DOM isn't reachable (e.g., non-browser
/// host or the canvas can't be created). Node is *not* appended
/// to the document — it lives only in memory.
fn get_mask_scratch(idx: usize, w: u32, h: u32) -> Option<(HtmlCanvasElement, CanvasRenderingContext2d)> {
    scratch_from_cell(&MASK_CANVAS, idx, w, h)
}

/// Second scratch canvas, used by the luminance-based mask path
/// to render the mask subtree in isolation before its alpha is
/// replaced by luminance.
fn get_mask_luma_scratch(idx: usize, w: u32, h: u32) -> Option<(HtmlCanvasElement, CanvasRenderingContext2d)> {
    scratch_from_cell(&MASK_LUMA_CANVAS, idx, w, h)
}

/// D-β's REPAIR, and the part of it that can be DRIVEN.
///
/// The defect (design block §2.2): both scratches were single static cells, so
/// `draw_element_with_mask` handed the SAME canvas to a nested call, whose
/// `clear_rect` wiped the outer call's half-drawn buffer. A masked group with a
/// masked child, or mask-in-mask, was silently wrong.
///
/// ⛔ THE ALIASING DECISION IS SEPARATED FROM THE CANVAS ON PURPOSE. The canvas
/// plumbing is `web_sys` and THIS REPO HAS NO WASM TEST HARNESS AT ALL — no
/// `wasm-bindgen-test` dependency, no wasm job in CI — so nothing in the canvas
/// path is executable by any suite here. What CAN be driven is the question the
/// defect actually turns on: *does a nested acquisition get a distinct buffer?*
/// That is pure bookkeeping, and it is `ScratchDepth` below.
#[derive(Debug, Default)]
pub(crate) struct ScratchDepth {
    depth: usize,
    high_water: usize,
}

impl ScratchDepth {
    /// Index of the buffer this acquisition owns. Nested acquisitions get
    /// DISTINCT indices — that is the whole repair.
    pub(crate) fn acquire(&mut self) -> usize {
        let i = self.depth;
        self.depth += 1;
        if self.depth > self.high_water {
            self.high_water = self.depth;
        }
        i
    }

    /// Saturating on purpose: an unbalanced release is a bug, but it must not
    /// panic inside a render pass and take the canvas down with it.
    pub(crate) fn release(&mut self) {
        self.depth = self.depth.saturating_sub(1);
    }

    pub(crate) fn live(&self) -> usize {
        self.depth
    }

    pub(crate) fn high_water(&self) -> usize {
        self.high_water
    }
}

/// RAII lease on a scratch depth. ⛔ IT IS A GUARD RATHER THAN A PAIRED CALL
/// BECAUSE `draw_element_with_mask` HAS EARLY RETURNS — three of them, each
/// falling back to the unmasked path. A hand-placed `release()` would be
/// skipped on those paths and the depth would ratchet upward for the rest of
/// the frame, so every later masked element would allocate a fresh buffer and
/// the pool would grow without bound. Drop cannot be forgotten.
pub(crate) struct ScratchLease(());

impl ScratchLease {
    pub(crate) fn acquire() -> (usize, Self) {
        let idx = MASK_SCRATCH_DEPTH.with(|d| d.borrow_mut().acquire());
        (idx, ScratchLease(()))
    }
}

impl Drop for ScratchLease {
    fn drop(&mut self) {
        MASK_SCRATCH_DEPTH.with(|d| d.borrow_mut().release());
    }
}

thread_local! {
    /// One depth counter per thread, mirroring the scratch cells it indexes.
    static MASK_SCRATCH_DEPTH: RefCell<ScratchDepth> = RefCell::new(ScratchDepth::default());
}

fn scratch_from_cell(
    cell: &'static std::thread::LocalKey<RefCell<Vec<HtmlCanvasElement>>>,
    idx: usize,
    w: u32, h: u32,
) -> Option<(HtmlCanvasElement, CanvasRenderingContext2d)> {
    // ⛔ D-β's REPAIR AT THE PLUMBING. `idx` is the nesting depth of THIS
    // acquisition, so an inner masked element never receives the buffer an
    // outer one is still drawing into. The pool GROWS to the deepest nesting
    // seen and is then reused — sequential masked elements share index 0, which
    // is the frame cost the original singleton existed to avoid.
    let canvas: HtmlCanvasElement = cell.with(|c| -> Option<HtmlCanvasElement> {
        if let Some(v) = c.borrow().get(idx).cloned() {
            return Some(v);
        }
        let window = web_sys::window()?;
        let doc = window.document()?;
        let el = doc.create_element("canvas").ok()?;
        let v: HtmlCanvasElement = el.unchecked_into();
        let mut pool = c.borrow_mut();
        while pool.len() <= idx {
            pool.push(v.clone());
        }
        Some(v)
    })?;
    if canvas.width() != w {
        canvas.set_width(w);
    }
    if canvas.height() != h {
        canvas.set_height(h);
    }
    let ctx: CanvasRenderingContext2d = canvas
        .get_context("2d").ok()??.unchecked_into();
    Some((canvas, ctx))
}

/// Promote the alpha channel of ``ctx``'s pixels within the given
/// device-space rectangle from raw alpha to luminance-scaled
/// alpha: ``A' = A * (0.299*R + 0.587*G + 0.114*B) / 255``. This
/// matches PDF §11's soft-mask convention — a black-opaque mask
/// reads as fully transparent, a white-opaque mask as fully
/// opaque, and a gray-opaque mask as partially opaque. Restricted
/// to the given rect for performance (typical masks occupy a
/// small fraction of the canvas).
///
/// Returns ``true`` on success. On ``None`` returns (ImageData
/// unavailable) the caller falls back to alpha-based masking so
/// the user's mask still has *some* effect, just not the
/// luminance-weighted one.
pub(crate) fn promote_mask_to_luminance(
    ctx: &CanvasRenderingContext2d,
    dx: i32, dy: i32, dw: u32, dh: u32,
) -> Option<()> {
    if dw == 0 || dh == 0 {
        return Some(());
    }
    let image_data = ctx
        .get_image_data(dx as f64, dy as f64, dw as f64, dh as f64)
        .ok()?;
    let data = image_data.data();
    let mut bytes: Vec<u8> = data.to_vec();
    promote_bytes_to_luminance(&mut bytes);
    let clamped = wasm_bindgen::Clamped(bytes.as_slice());
    let new_data = web_sys::ImageData::new_with_u8_clamped_array_and_sh(
        clamped, dw, dh,
    ).ok()?;
    ctx.put_image_data(&new_data, dx as f64, dy as f64).ok()?;
    Some(())
}

/// Replace each RGBA pixel's alpha channel with
/// ``A' = A * (0.299*R + 0.587*G + 0.114*B) / 255``. Pure
/// function, testable without a live canvas.
fn promote_bytes_to_luminance(bytes: &mut [u8]) {
    let mut i = 0;
    while i + 3 < bytes.len() {
        let r = bytes[i] as f64;
        let g = bytes[i + 1] as f64;
        let b = bytes[i + 2] as f64;
        let a = bytes[i + 3] as f64;
        // ITU-R BT.601 luma weights; integers would be faster but
        // the f64 form is clear and the inner loop is
        // getImageData-bound anyway.
        let lum = 0.299 * r + 0.587 * g + 0.114 * b;
        let new_alpha = (lum * a / 255.0).round().clamp(0.0, 255.0) as u8;
        bytes[i + 3] = new_alpha;
        i += 4;
    }
}

/// Apply the ``ClipIn`` luminance composite on an offscreen
/// canvas that already holds the rendered element body. Returns
/// ``true`` on success, ``false`` when any intermediate step
/// fails so the caller can fall back to alpha-based compositing.
/// ``off_ctx`` must carry the mask's effective transform applied
/// on top of the main world transform.
///
/// Steps:
///   1. Render the mask subtree in isolation onto the luma
///      scratch canvas (a fresh transparent buffer, same
///      transform as ``off_ctx``).
///   2. Promote that scratch's pixels from raw alpha to
///      luminance-scaled alpha (black-opaque → fully transparent,
///      white-opaque → fully opaque, gray → partial).
///   3. Blit the luma scratch onto the element-body buffer with
///      ``destination-in``; the luminance alpha clips the element.
fn apply_clip_in_luminance(
    // ⛔ THE CALLER'S DEPTH, NOT A FRESH ONE. This helper runs INSIDE
    // draw_element_with_mask's lease and belongs to the SAME nesting level; the
    // luma pool is a second buffer at that depth, not a deeper acquisition.
    // Acquiring here would double-count the depth and grow both pools twice as
    // fast for no isolation gained.
    scratch_idx: usize,
    off_ctx: &CanvasRenderingContext2d,
    w: u32,
    h: u32,
    mask: &Mask,
    ancestor_vis: Visibility,
    precision: f64,
) -> bool {
    let (luma_canvas, luma_ctx) = match get_mask_luma_scratch(scratch_idx, w, h) {
        Some(p) => p,
        None => return false,
    };
    luma_ctx.set_transform(1.0, 0.0, 0.0, 1.0, 0.0, 0.0).ok();
    luma_ctx.set_global_composite_operation("source-over").ok();
    luma_ctx.set_global_alpha(1.0);
    luma_ctx.clear_rect(0.0, 0.0, w as f64, h as f64);
    if let Some((a, b, c, d, e, f)) = read_ctx_transform(off_ctx) {
        luma_ctx.set_transform(a, b, c, d, e, f).ok();
    }
    draw_element(&luma_ctx, &mask.subtree, ancestor_vis, precision);
    if promote_mask_to_luminance(&luma_ctx, 0, 0, w, h).is_none() {
        return false;
    }
    // Guarded so the identity transform + destination-in are popped on
    // every exit; the block ends the span before the `true` tail, exactly
    // where the manual restore() stood (see CtxSaveGuard).
    {
        let _ctx_guard = CtxSaveGuard::new(off_ctx);
        off_ctx.set_transform(1.0, 0.0, 0.0, 1.0, 0.0, 0.0).ok();
        off_ctx.set_global_composite_operation("destination-in").ok();
        let _ = off_ctx.draw_image_with_html_canvas_element(&luma_canvas, 0.0, 0.0);
    }
    true
}

/// Render ``elem`` on the main ``ctx`` with its opacity mask
/// composited in. The element body is drawn to a scratch
/// offscreen canvas at the same world transform as the main ctx;
/// the mask's subtree is then composited according to ``plan``.
/// The scratch canvas is finally copied onto the main ctx at
/// device coordinates.
fn draw_element_with_mask(
    ctx: &CanvasRenderingContext2d,
    elem: &Element,
    mask: &Mask,
    plan: MaskPlan,
    ancestor_vis: Visibility,
    precision: f64,
    element_scale: f64,
) {
    // The inherited ancestor-group alpha product, read BEFORE this function
    // touches `ctx`. Same idiom as the unmasked path (`draw_element_body`
    // captures `ctx.global_alpha()` for exactly this reason); it is what the
    // blit below multiplies the composited scratch by.
    let parent_alpha = ctx.global_alpha();
    // D-β: take a depth BEFORE anything else, and hold it for the whole call.
    // The lease releases on every exit path, including the early fallbacks.
    let (scratch_idx, _lease) = ScratchLease::acquire();
    let main_canvas = ctx.canvas();
    let (w, h) = match &main_canvas {
        Some(c) => (c.width(), c.height()),
        None => {
            // No canvas reachable — fall back to the no-mask path.
            draw_element_body(ctx, elem, ancestor_vis, precision, element_scale);
            return;
        }
    };
    if w == 0 || h == 0 {
        return;
    }
    let (off_canvas, off_ctx) = match get_mask_scratch(scratch_idx, w, h) {
        Some(pair) => pair,
        None => {
            draw_element_body(ctx, elem, ancestor_vis, precision, element_scale);
            return;
        }
    };

    // Reset offscreen state and clear any prior content.
    off_ctx.set_transform(1.0, 0.0, 0.0, 1.0, 0.0, 0.0).ok();
    off_ctx.set_global_composite_operation("source-over").ok();
    off_ctx.set_global_alpha(1.0);
    off_ctx.clear_rect(0.0, 0.0, w as f64, h as f64);

    // Copy the main ctx's current world transform onto the offscreen
    // ctx so ``elem`` renders at the same screen position it would
    // on the main canvas. web-sys 0.3 doesn't expose
    // ``getTransform()`` / ``DOMMatrix`` under the enabled features,
    // so read ``currentTransform`` via JS reflection — the object
    // has ``a``..``f`` number fields matching the 2D matrix.
    if let Some((a, b, c, d, e, f)) = read_ctx_transform(ctx) {
        off_ctx.set_transform(a, b, c, d, e, f).ok();
    }

    // Pass 1: draw the element body (skipping the mask dispatch so
    // we don't recurse into ourselves) onto the offscreen canvas. The
    // masked element carries the inherited element-transform scale so its
    // own stroke is counter-scaled like any other.
    draw_element_body(&off_ctx, elem, ancestor_vis, precision, element_scale);

    // Pass 2: apply the mask's effective transform (per
    // ``effective_mask_transform``), then composite the mask
    // subtree against the element body. The explicit block ends the
    // guarded span exactly where the manual restore() stood — the blit
    // below must run in the popped state.
    {
        let _ctx_guard = CtxSaveGuard::new(&off_ctx);
        if let Some(t) = effective_mask_transform(mask, elem) {
            off_ctx.transform(t.a, t.b, t.c, t.d, t.e, t.f).ok();
        }
        match plan {
            MaskPlan::ClipIn => {
                // Luminance-based soft-mask composite. The mask subtree
                // is rendered to a separate scratch, its alpha is
                // replaced by the per-pixel luminance (so a black
                // opaque mask reads as fully transparent and a white
                // opaque mask reads as fully opaque), and then the
                // result is drawn onto the element buffer with
                // ``destination-in``. Matches PDF §11's soft-mask
                // convention. OPACITY.md §Rendering.
                //
                // If any step of the luminance path fails (ImageData
                // unavailable, zero-size canvas, …) we fall back to
                // the alpha-based composite so the user still sees
                // *something*.
                let fell_back = !apply_clip_in_luminance(
                    scratch_idx,
                    &off_ctx, w, h, mask, ancestor_vis, precision,
                );
                if fell_back {
                    off_ctx.set_global_composite_operation("destination-in").ok();
                    draw_element(&off_ctx, &mask.subtree, ancestor_vis, precision);
                }
            }
            MaskPlan::ClipOut => {
                // `destination-out` over the whole canvas — the mask
                // shape erases the element.
                off_ctx.set_global_composite_operation("destination-out").ok();
                draw_element(&off_ctx, &mask.subtree, ancestor_vis, precision);
            }
            MaskPlan::RevealOutsideBbox => {
                // `clip: false, invert: false`: the element keeps full
                // alpha outside the mask subtree's bounding box, and is
                // clipped to the mask shape only inside it. Implement
                // by clipping the Canvas2D state to the bbox rectangle
                // before applying `destination-in`; outside the clip,
                // the element remains untouched.
                let (bx, by, bw, bh) = mask.subtree.bounds();
                if bw > 0.0 && bh > 0.0 {
                    // Guarded: the bbox clip + destination-in pop at the
                    // end of this branch (see CtxSaveGuard).
                    let _ctx_guard = CtxSaveGuard::new(&off_ctx);
                    off_ctx.begin_path();
                    off_ctx.rect(bx, by, bw, bh);
                    off_ctx.clip();
                    off_ctx.set_global_composite_operation("destination-in").ok();
                    draw_element(&off_ctx, &mask.subtree, ancestor_vis, precision);
                    off_ctx.set_global_composite_operation("source-over").ok();
                }
                // Empty-bbox mask: no clip region; the element
                // body passes through unmodified (mask has nothing to
                // composite against).
            }
        }
    }

    // Copy the composited offscreen pixels onto the main ctx at
    // device coordinates (0, 0), under the INHERITED ancestor-group alpha —
    // which is what the comment here always claimed ("the main ctx's alpha
    // will apply to the final blit, matching the non-mask path") and what
    // `set_global_alpha(elem.opacity())` used to contradict on the line below
    // it: that both squared the element's own opacity (the body pass already
    // applied it on the scratch) and REPLACED the ancestors' product rather
    // than multiplying into it. See [mask_blit_alpha] for the law.
    // Guarded: the identity transform + blend state pop when this
    // function returns, on every path (see CtxSaveGuard).
    let _ctx_guard = CtxSaveGuard::new(ctx);
    ctx.set_transform(1.0, 0.0, 0.0, 1.0, 0.0, 0.0).ok();
    ctx.set_global_alpha(mask_blit_alpha(parent_alpha, elem.opacity()));
    ctx.set_global_composite_operation(blend_mode_css(elem.mode())).ok();
    ctx.draw_image_with_html_canvas_element(&off_canvas, 0.0, 0.0).ok();
}

// ---------------------------------------------------------------------------
// Element body (non-mask path)
// ---------------------------------------------------------------------------

/// Render an element's geometry (fill / stroke / children) without
/// consulting ``common.mask``. Split from [draw_element] so the
/// mask path can invoke the body directly without recursing through
/// the mask dispatch.
fn draw_element_body(
    ctx: &CanvasRenderingContext2d,
    elem: &Element,
    ancestor_vis: Visibility,
    precision: f64,
    element_scale: f64,
) {
    // Effective visibility is the minimum of the inherited (capping)
    // visibility and this element's own. Groups/Layers propagate the
    // cap down to their children; Invisible stops the recursion.
    let effective = std::cmp::min(ancestor_vis, elem.visibility());
    if effective == Visibility::Invisible {
        return;
    }
    let outline = effective == Visibility::Outline;

    // Capture the inherited alpha BEFORE the save; save+set replaces
    // it, but we want this element's effective alpha to MULTIPLY into
    // any outer alpha (parent group opacity, isolation dim) rather
    // than replace it. The guard's save takes the current alpha; its
    // Drop pops it back when this element finishes.
    let parent_alpha = ctx.global_alpha();
    // RAII-balanced save: restores on every exit path (see CtxSaveGuard).
    let _ctx_guard = CtxSaveGuard::new(ctx);
    apply_transform(ctx, elem.transform());
    // Counter-scale the element's own stroke at the SOURCE: rebind `elem` to a
    // copy whose stroke width is divided by the accumulated element-transform
    // scale, so the element transform (now on the painter) does NOT thicken it
    // — it renders at the nominal, zoom-scaled width, cancelling the matrix's
    // stroke scaling and the scale_strokes double-scale. Because the divided
    // width lives on the element itself, EVERY stroke.width reader below (the
    // pen width AND the Line arrowhead setback) sees it. `elem_scale` is
    // threaded to children. Uses the ELEMENT chain only — stroke still scales
    // with zoom. Matches the Python/OCaml element-copy reference.
    let (elem_copy, elem_scale) = counter_scaled_element(elem, element_scale);
    let elem = &elem_copy;
    let base_alpha = parent_alpha * elem.opacity();
    ctx.set_global_alpha(base_alpha);
    ctx.set_global_composite_operation(blend_mode_css(elem.mode())).ok();

    match elem {
        Element::Line(e) => {
            // PH1 Painter conversion (capability-routed). A plain
            // center-aligned, solid, arrowless line's leaf paint routes through
            // Canvas2dPainter — BYTE-IDENTICAL to the legacy body below (see
            // `painter::element_render::line_painter_inputs` for the exact
            // ctx-sequence equivalence argument). The shared per-element
            // prologue/epilogue (save · transform · global_alpha(base_alpha) ·
            // composite · restore) stays raw ctx; only the leaf paint is
            // rewritten. Any line needing an arrowhead / variable width /
            // inside-outside alignment / a stroke gradient / anchor-aligned
            // dashing, or in outline mode, falls through to the unchanged
            // legacy path.
            let converted = if outline {
                false
            } else if let Some(lp) = crate::painter::element_render::line_painter_inputs(e) {
                use crate::painter::Painter as _;
                let mut painter = crate::painter::canvas2d::Canvas2dPainter::new(ctx);
                painter.stroke_path(&lp.path, &lp.brush, &lp.stroke, base_alpha * lp.stroke_op);
                true
            } else {
                false
            };
            if !converted {
            let (mut stroke_op, mut stroke_align) = (1.0, StrokeAlign::Center);
            if outline {
                apply_outline_style(ctx);
            } else {
                (stroke_op, stroke_align) = apply_stroke(ctx, e.stroke.as_ref());
            }
            // Shorten line endpoints to accommodate arrowheads
            let (mut lx1, mut ly1, mut lx2, mut ly2) = (e.x1, e.y1, e.x2, e.y2);
            if !outline {
                if let Some(s) = e.stroke.as_ref() {
                    let dx = lx2 - lx1;
                    let dy = ly2 - ly1;
                    let len = (dx * dx + dy * dy).sqrt();
                    if len > 0.0 {
                        let ux = dx / len;
                        let uy = dy / len;
                        let start_sb = super::arrowheads::arrow_setback(
                            s.start_arrow.as_str(), s.width, s.start_arrow_scale);
                        let end_sb = super::arrowheads::arrow_setback(
                            s.end_arrow.as_str(), s.width, s.end_arrow_scale);
                        lx1 += ux * start_sb;
                        ly1 += uy * start_sb;
                        lx2 -= ux * end_sb;
                        ly2 -= uy * end_sb;
                    }
                }
            }
            ctx.set_global_alpha(base_alpha * stroke_op);
            if !outline && !e.width_points.is_empty() {
                // Variable-width stroke via offset paths
                if let Some(s) = e.stroke.as_ref() {
                    let color = css_color(&s.color);
                    crate::algorithms::offset_path::render_variable_width_line(
                        ctx, lx1, ly1, lx2, ly2,
                        &e.width_points, &color, s.linecap,
                    );
                }
            } else {
                ctx.begin_path();
                ctx.move_to(lx1, ly1);
                ctx.line_to(lx2, ly2);
                stroke_aligned(ctx, stroke_align);
            }
            // Arrowheads — oriented off the ORIGINAL endpoints (e.x1..e.y2),
            // never the shortened lx1..ly2 used for the stroke body.
            if !outline {
                if let Some(s) = e.stroke.as_ref() {
                    let color = css_color(&s.color);
                    let center = s.arrow_align == ArrowAlign::CenterAtEnd;
                    super::arrowheads::draw_arrowheads_line(
                        ctx, e.x1, e.y1, e.x2, e.y2,
                        s.start_arrow.as_str(), s.end_arrow.as_str(),
                        s.start_arrow_scale, s.end_arrow_scale,
                        s.width, &color, center,
                    );
                }
            }
            } // end `if !converted`: the PH1 painter route handled the leaf paint
        }
        Element::Rect(e) => {
            // PH2 Painter conversion (capability-routed), mirroring the Line arm.
            // A convertible Rect's fill+stroke leaf paint routes through
            // Canvas2dPainter — display-list-equivalent to the legacy body below
            // (the fill/stroke reorder is pixel-identical; see the PH2 design).
            // A freeform gradient or anchor-dash expansion (which the two-paint
            // seam can't reproduce), and outline mode, fall through unchanged.
            let converted = if outline {
                false
            } else if let Some(sp) = crate::painter::element_render::rect_painter_inputs(
                e, (e.x, e.y, e.width, e.height),
            ) {
                let mut painter = crate::painter::canvas2d::Canvas2dPainter::new(ctx);
                crate::painter::element_render::emit_shape_paint(&mut painter, &sp, base_alpha);
                true
            } else {
                false
            };
            if !converted {
            let (mut fill_op, mut stroke_op, mut stroke_align) = (1.0, 1.0, StrokeAlign::Center);
            if outline {
                apply_outline_style(ctx);
            } else {
                let bbox = (e.x, e.y, e.width, e.height);
                fill_op = apply_fill(ctx, e.fill.as_ref(),
                    e.fill_gradient.as_deref(), bbox);
                (stroke_op, stroke_align) = apply_stroke_with_gradient(
                    ctx, e.stroke.as_ref(),
                    e.stroke_gradient.as_deref(), bbox);
            }
            let has_fill = !outline && (e.fill.is_some() || e.fill_gradient.is_some());
            let has_stroke = outline || e.stroke.is_some();
            if e.rx > 0.0 || e.ry > 0.0 {
                let rx = e.rx.max(0.0).min(e.width / 2.0);
                let ry = e.ry.max(0.0).min(e.height / 2.0);
                let x = e.x;
                let y = e.y;
                let w = e.width;
                let h = e.height;
                ctx.begin_path();
                ctx.move_to(x + rx, y);
                ctx.line_to(x + w - rx, y);
                ctx.quadratic_curve_to(x + w, y, x + w, y + ry);
                ctx.line_to(x + w, y + h - ry);
                ctx.quadratic_curve_to(x + w, y + h, x + w - rx, y + h);
                ctx.line_to(x + rx, y + h);
                ctx.quadratic_curve_to(x, y + h, x, y + h - ry);
                ctx.line_to(x, y + ry);
                ctx.quadratic_curve_to(x, y, x + rx, y);
                ctx.close_path();
                if has_fill {
                    ctx.set_global_alpha(base_alpha * fill_op);
                    ctx.fill();
                }
                if has_stroke {
                    ctx.set_global_alpha(base_alpha * stroke_op);
                    stroke_aligned(ctx, stroke_align);
                }
            } else {
                if has_fill {
                    ctx.set_global_alpha(base_alpha * fill_op);
                    ctx.fill_rect(e.x, e.y, e.width, e.height);
                }
                if has_stroke {
                    ctx.set_global_alpha(base_alpha * stroke_op);
                    let dasher_active = e.stroke.as_ref()
                        .map(|s| s.dash_align_anchors && !s.dash_array().is_empty())
                        .unwrap_or(false);
                    if dasher_active {
                        let s = e.stroke.as_ref().unwrap();
                        let cmds = vec![
                            PathCommand::MoveTo { x: e.x, y: e.y },
                            PathCommand::LineTo { x: e.x + e.width, y: e.y },
                            PathCommand::LineTo { x: e.x + e.width, y: e.y + e.height },
                            PathCommand::LineTo { x: e.x, y: e.y + e.height },
                            PathCommand::ClosePath,
                        ];
                        let expanded = crate::algorithms::dash_renderer::expand_dashed_stroke(
                            &cmds, s.dash_array(), true);
                        for sub in &expanded {
                            ctx.begin_path();
                            build_path(ctx, sub);
                            stroke_aligned(ctx, stroke_align);
                        }
                    } else {
                        // Use path-based stroke for alignment support
                        ctx.begin_path();
                        ctx.rect(e.x, e.y, e.width, e.height);
                        stroke_aligned(ctx, stroke_align);
                    }
                }
            }
            } // end `if !converted`: the PH2 painter route handled the paints
        }
        Element::Ellipse(e) => {
            // PH2 Painter conversion (capability-routed). RP3 as Circle: a
            // non-center stroke stays legacy. Freeform gradient / outline fall
            // through unchanged.
            let converted = if outline {
                false
            } else if let Some(sp) = crate::painter::element_render::ellipse_painter_inputs(
                e, (e.cx - e.rx, e.cy - e.ry, e.rx * 2.0, e.ry * 2.0),
            ) {
                let mut painter = crate::painter::canvas2d::Canvas2dPainter::new(ctx);
                crate::painter::element_render::emit_shape_paint(&mut painter, &sp, base_alpha);
                true
            } else {
                false
            };
            if !converted {
            let (mut fill_op, mut stroke_op, mut stroke_align) = (1.0, 1.0, StrokeAlign::Center);
            if outline {
                apply_outline_style(ctx);
            } else {
                let bbox = (e.cx - e.rx, e.cy - e.ry, e.rx * 2.0, e.ry * 2.0);
                fill_op = apply_fill(ctx, e.fill.as_ref(),
                    e.fill_gradient.as_deref(), bbox);
                (stroke_op, stroke_align) = apply_stroke_with_gradient(
                    ctx, e.stroke.as_ref(),
                    e.stroke_gradient.as_deref(), bbox);
            }
            ctx.begin_path();
            ctx.ellipse(e.cx, e.cy, e.rx, e.ry, 0.0, 0.0, std::f64::consts::TAU)
                .ok();
            if !outline && (e.fill.is_some() || e.fill_gradient.is_some()) {
                ctx.set_global_alpha(base_alpha * fill_op);
                ctx.fill();
            }
            if outline || e.stroke.is_some() {
                ctx.set_global_alpha(base_alpha * stroke_op);
                stroke_aligned(ctx, stroke_align);
            }
            } // end `if !converted`: the PH2 painter route handled the paints
        }
        Element::Polyline(e) => {
            // PH2 Painter conversion (capability-routed). Inside/outside strokes
            // ride the path clip lowering; a freeform gradient, an empty point
            // list, or outline mode falls through to the unchanged legacy path.
            let converted = if outline {
                false
            } else if let Some(sp) =
                crate::painter::element_render::polyline_painter_inputs(e, poly_bbox(&e.points))
            {
                let mut painter = crate::painter::canvas2d::Canvas2dPainter::new(ctx);
                crate::painter::element_render::emit_shape_paint(&mut painter, &sp, base_alpha);
                true
            } else {
                false
            };
            if !converted {
            let (mut fill_op, mut stroke_op, mut stroke_align) = (1.0, 1.0, StrokeAlign::Center);
            if outline {
                apply_outline_style(ctx);
            } else {
                let bbox = poly_bbox(&e.points);
                fill_op = apply_fill(ctx, e.fill.as_ref(),
                    e.fill_gradient.as_deref(), bbox);
                (stroke_op, stroke_align) = apply_stroke_with_gradient(
                    ctx, e.stroke.as_ref(),
                    e.stroke_gradient.as_deref(), bbox);
            }
            if !e.points.is_empty() {
                ctx.begin_path();
                ctx.move_to(e.points[0].0, e.points[0].1);
                for &(x, y) in &e.points[1..] {
                    ctx.line_to(x, y);
                }
                if !outline && (e.fill.is_some() || e.fill_gradient.is_some()) {
                    ctx.set_global_alpha(base_alpha * fill_op);
                    ctx.fill();
                }
                if outline || e.stroke.is_some() {
                    ctx.set_global_alpha(base_alpha * stroke_op);
                    stroke_aligned(ctx, stroke_align);
                }
            }
            } // end `if !converted`: the PH2 painter route handled the paints
        }
        Element::Polygon(e) => {
            // PH2 Painter conversion (capability-routed). Inside/outside strokes
            // ride the path clip lowering; a freeform gradient, an empty point
            // list, or outline mode falls through to the unchanged legacy path.
            let converted = if outline {
                false
            } else if let Some(sp) =
                crate::painter::element_render::polygon_painter_inputs(e, poly_bbox(&e.points))
            {
                let mut painter = crate::painter::canvas2d::Canvas2dPainter::new(ctx);
                crate::painter::element_render::emit_shape_paint(&mut painter, &sp, base_alpha);
                true
            } else {
                false
            };
            if !converted {
            let (mut fill_op, mut stroke_op, mut stroke_align) = (1.0, 1.0, StrokeAlign::Center);
            if outline {
                apply_outline_style(ctx);
            } else {
                let bbox = poly_bbox(&e.points);
                fill_op = apply_fill(ctx, e.fill.as_ref(),
                    e.fill_gradient.as_deref(), bbox);
                (stroke_op, stroke_align) = apply_stroke_with_gradient(
                    ctx, e.stroke.as_ref(),
                    e.stroke_gradient.as_deref(), bbox);
            }
            if !e.points.is_empty() {
                ctx.begin_path();
                ctx.move_to(e.points[0].0, e.points[0].1);
                for &(x, y) in &e.points[1..] {
                    ctx.line_to(x, y);
                }
                ctx.close_path();
                if !outline && (e.fill.is_some() || e.fill_gradient.is_some()) {
                    ctx.set_global_alpha(base_alpha * fill_op);
                    ctx.fill();
                }
                if outline || e.stroke.is_some() {
                    ctx.set_global_alpha(base_alpha * stroke_op);
                    stroke_aligned(ctx, stroke_align);
                }
            }
            } // end `if !converted`: the PH2 painter route handled the paints
        }
        Element::Path(e) => {
            // PH2 Painter conversion (capability-routed). RP2: a set stroke
            // brush renders a filled outline (draw_brushed_path), nothing like a
            // native stroke — it stays legacy, together with variable width,
            // arrowheads, anchor-dash expansion, freeform gradients, and outline
            // mode. The gradient bbox is `elem.bounds()` — exactly the box the
            // legacy arm passes (for Path that box IS bounds()). The A3 fill
            // winding is the element's fill_rule.
            let converted = if outline {
                false
            } else if let Some(sp) =
                crate::painter::element_render::path_painter_inputs(e, elem.bounds())
            {
                let mut painter = crate::painter::canvas2d::Canvas2dPainter::new(ctx);
                crate::painter::element_render::emit_shape_paint(&mut painter, &sp, base_alpha);
                true
            } else {
                false
            };
            if !converted {
            let (mut fill_op, mut stroke_op, mut stroke_align) = (1.0, 1.0, StrokeAlign::Center);
            if outline {
                apply_outline_style(ctx);
            } else {
                let b = elem.bounds();
                fill_op = apply_fill(ctx, e.fill.as_ref(),
                    e.fill_gradient.as_deref(), b);
                (stroke_op, stroke_align) = apply_stroke_with_gradient(
                    ctx, e.stroke.as_ref(),
                    e.stroke_gradient.as_deref(), b);
            }
            // Fill uses the original path
            if !outline && (e.fill.is_some() || e.fill_gradient.is_some()) {
                ctx.begin_path();
                build_path(ctx, &e.d);
                ctx.set_global_alpha(base_alpha * fill_op);
                match e.fill_rule {
                    crate::geometry::element::FillRule::NonZero => ctx.fill(),
                    crate::geometry::element::FillRule::EvenOdd => ctx.fill_with_canvas_winding_rule(
                        web_sys::CanvasWindingRule::Evenodd,
                    ),
                }
            }
            // Brushed stroke — when stroke_brush resolves to a known
            // Calligraphic brush, draw its variable-width outline as a
            // filled polygon using the element's stroke colour. Skips
            // the native stroke / arrowhead pipeline below. See
            // BRUSHES.md §Stroke styling interaction.
            //
            // Gate the native stroke + arrowhead sections on this flag
            // rather than `return`ing from here: this branch is the
            // WEDGESTORM site, where the early return skipped the
            // epilogue restore() and leaked one save per brushed frame
            // (every later repaint then compounded the view transform on
            // the leaked state — the "receding artboard cascade"). The
            // prologue's CtxSaveGuard now makes such a return harmless,
            // but the flag is also what the surrounding sections mean:
            // the brush renderer owns the whole stroke appearance.
            let stroke_brushed = if !outline && e.stroke_brush.is_some() {
                ctx.set_global_alpha(base_alpha * stroke_op);
                // False when the slug didn't resolve or the brush type
                // isn't supported yet → fall through to native stroke.
                draw_brushed_path(ctx, e, outline)
            } else {
                false
            };
            // Stroke uses an arc-length-trimmed path to accommodate arrowheads:
            // walk in from each armed end by the setback along arc length, split
            // the straddled segment (de Casteljau), drop the tail. Replaces the
            // old anchor-displacement (which deformed curved ends and folded them
            // past the head at large setbacks). An empty result means the setbacks
            // meet-or-exceed the length -> heads-only, no stroke; every draw path
            // below no-ops on empty cmds, and the arrowheads still draw off `e.d`.
            if !stroke_brushed && (outline || e.stroke.is_some()) {
                let trimmed = if !outline {
                    if let Some(s) = e.stroke.as_ref() {
                        let start_sb = super::arrowheads::arrow_setback(
                            s.start_arrow.as_str(), s.width, s.start_arrow_scale);
                        let end_sb = super::arrowheads::arrow_setback(
                            s.end_arrow.as_str(), s.width, s.end_arrow_scale);
                        if start_sb > 0.0 || end_sb > 0.0 {
                            Some(crate::algorithms::arrow_trim::trim_path(&e.d, start_sb, end_sb))
                        } else { None }
                    } else { None }
                } else { None };
                // Butt the trimmed cut: the head covers the stroke's end at the
                // head base, so a round/projecting cap there would poke half a
                // width into/under the head. A single canvas stroke carries one
                // cap, so this also butts a one-armed path's free end — an
                // accepted simplification; arrowheaded ends are the target.
                if trimmed.is_some() {
                    ctx.set_line_cap("butt");
                }
                let stroke_cmds = trimmed.as_deref().unwrap_or(&e.d);
                ctx.set_global_alpha(base_alpha * stroke_op);
                if !outline && !e.width_points.is_empty() {
                    // Variable-width stroke via offset paths
                    if let Some(s) = e.stroke.as_ref() {
                        let color = css_color(&s.color);
                        crate::algorithms::offset_path::render_variable_width_path(
                            ctx, stroke_cmds, &e.width_points, &color, s.linecap,
                        );
                    }
                } else if let Some(s) = e.stroke.as_ref() {
                    if s.dash_align_anchors && !s.dash_array().is_empty() {
                        // Anchor-aligned dashing: expand into solid
                        // sub-paths and stroke each. apply_stroke
                        // already cleared the platform's dash array.
                        let expanded = crate::algorithms::dash_renderer::expand_dashed_stroke(
                            stroke_cmds, s.dash_array(), true);
                        for sub in &expanded {
                            ctx.begin_path();
                            build_path(ctx, sub);
                            stroke_aligned(ctx, stroke_align);
                        }
                    } else {
                        ctx.begin_path();
                        build_path(ctx, stroke_cmds);
                        stroke_aligned(ctx, stroke_align);
                    }
                } else {
                    ctx.begin_path();
                    build_path(ctx, stroke_cmds);
                    stroke_aligned(ctx, stroke_align);
                }
            }
            // Arrowheads — anchored at the ORIGINAL `e.d` endpoints, never the
            // shortened/trimmed `stroke_cmds`. The ANGLE is the trim-chord over
            // each head's footprint (from the trim cut-point to the original
            // endpoint), so end-hooks and degenerate micro-segments can't swing
            // it. See the orientation contract on draw_arrowheads.
            if !stroke_brushed && !outline {
                if let Some(s) = e.stroke.as_ref() {
                    let color = css_color(&s.color);
                    let center = s.arrow_align == ArrowAlign::CenterAtEnd;
                    let start_sb = super::arrowheads::arrow_setback(
                        s.start_arrow.as_str(), s.width, s.start_arrow_scale);
                    let end_sb = super::arrowheads::arrow_setback(
                        s.end_arrow.as_str(), s.width, s.end_arrow_scale);
                    super::arrowheads::draw_arrowheads(
                        ctx, &e.d,
                        s.start_arrow.as_str(), s.end_arrow.as_str(),
                        s.start_arrow_scale, s.end_arrow_scale,
                        s.width, &color, center,
                        start_sb, end_sb,
                    );
                }
            }
            } // end `if !converted`: the PH2 painter route handled the paints
        }
        Element::Text(e) => {
            let fill_op = apply_fill(ctx, e.fill.as_ref(), None, (0.0, 0.0, 0.0, 0.0));
            ctx.set_global_alpha(base_alpha * fill_op);
            // Multi-tspan text renders each tspan with its own
            // effective font (family / size / weight / style) and
            // text-decoration on a shared baseline. Single no-override
            // tspan falls through to the flat fast path below. First
            // pass covers the visible subset — font + decoration
            // overrides per tspan; per-tspan baseline-shift / rotate /
            // transform / dx / wrapping come in follow-ups.
            let is_flat = e.render_is_flat();
            if !is_flat {
                draw_segmented_text(ctx, e);
            } else {
            // Baseline-shift: super/sub render at a smaller size and
            // offset from the baseline.
            let (size_scale, y_shift) = match e.baseline_shift.as_str() {
                "super" => (0.7, -e.font_size * 0.35),
                "sub"   => (0.7,  e.font_size * 0.2),
                // Numeric "Npt" — shift up by N points, keep size.
                other => crate::workspace::app_state::parse_pt(other)
                    .map(|pt| (1.0_f64, -pt))
                    .unwrap_or((1.0, 0.0)),
            };
            let effective_fs = e.font_size * size_scale;
            let font = format!("{} {} {}px {}", e.font_style, e.font_weight, effective_fs, e.font_family);
            ctx.set_font(&font);
            // Letter-spacing = tracking + kerning (Canvas 2D has no
            // per-pair kerning, so numeric kerning adds to the
            // uniform letter-spacing advance — same cheap
            // approximation both fields use.)
            let ls_em = if !e.letter_spacing.is_empty() {
                crate::workspace::app_state::parse_em_as_thousandths(&e.letter_spacing)
                    .unwrap_or(0.0)
            } else { 0.0 };
            let kern_em = if !e.kerning.is_empty() {
                crate::workspace::app_state::parse_em_as_thousandths(&e.kerning)
                    .unwrap_or(0.0)
            } else { 0.0 };
            let ls_px = (ls_em + kern_em) * effective_fs / 1000.0;
            if ls_px != 0.0 {
                let _ = js_sys::Reflect::set(
                    ctx,
                    &js_sys::JsString::from("letterSpacing"),
                    &js_sys::JsString::from(format!("{}px", ls_px).as_str()),
                );
            }
            // V/H scale wraps the whole text draw. Character rotation
            // is *per-glyph* (matches SVG's <text rotate="N"> spec and
            // the Character panel's Rotation field): each glyph
            // rotates around its own baseline position, leaving the
            // overall layout on a horizontal baseline.
            let h_scale = if e.horizontal_scale.is_empty() { 1.0 }
                else { e.horizontal_scale.parse::<f64>().unwrap_or(100.0) / 100.0 };
            let v_scale = if e.vertical_scale.is_empty() { 1.0 }
                else { e.vertical_scale.parse::<f64>().unwrap_or(100.0) / 100.0 };
            let rotate_deg = if e.rotate.is_empty() { 0.0 }
                else { e.rotate.parse::<f64>().unwrap_or(0.0) };
            let rotate_rad = rotate_deg.to_radians();
            let needs_scale = h_scale != 1.0 || v_scale != 1.0;
            // Conditional guarded save: `Some` only when the v/h-scale frame
            // is actually pushed. Drop pops it at the end of this branch —
            // where the paired `if needs_scale { ctx.restore(); }` stood
            // (see CtxSaveGuard).
            let _scale_guard = if needs_scale {
                let guard = CtxSaveGuard::new(ctx);
                ctx.translate(e.x, e.y).ok();
                ctx.scale(h_scale, v_scale).ok();
                ctx.translate(-e.x, -e.y).ok();
                Some(guard)
            } else {
                None
            };
            let measure = crate::tools::text_measure::make_measurer(&font, effective_fs);
            let max_w = if e.is_area_text() { e.width } else { 0.0 };
            // text-transform / font-variant: small-caps is rendered as
            // uppercase-with-same-size for now (close-enough placeholder
            // until OpenType small-caps substitution lands).
            let raw = e.content();
            let content_str = if e.text_transform == "uppercase"
                || e.font_variant == "small-caps"
            {
                raw.to_uppercase()
            } else if e.text_transform == "lowercase" {
                raw.to_lowercase()
            } else {
                raw
            };
            // Leading: line_height in pt (empty = Auto = font_size).
            // The text_layout::layout function uses its font_size
            // argument as the line height, so pass the leading value
            // there when set. Kept equal to font_size for Auto.
            //
            // Phase 8: when line_height is empty (Character Auto) and
            // the first paragraph wrapper carries jas:auto-leading,
            // override the Auto default with `auto_leading%` of the
            // font size. Per-paragraph leading would need text_layout
            // to take per-segment font_size; V1 applies one Auto
            // override element-wide using the first wrapper's value.
            let leading_px = if e.line_height.is_empty() {
                let auto_leading_pct = e.tspans.iter()
                    .find(|t| t.jas_role.as_deref() == Some("paragraph"))
                    .and_then(|t| t.jas_auto_leading);
                match auto_leading_pct {
                    Some(pct) => effective_fs * pct / 100.0,
                    None => effective_fs,  // pre-existing: Auto = 100%
                }
            } else {
                crate::workspace::app_state::parse_pt(&e.line_height).unwrap_or(effective_fs)
            };
            // Phase 5: build paragraph segments from the wrapper
            // tspans (jas_role == "paragraph"). The wrapper's
            // [left/right/first-line] indent and [space-before/after]
            // attributes are pt — convert to px (1pt == 1px in the
            // canvas coordinate space we use). Alignment maps the
            // §Alignment sub-mapping per area / point text.
            let segments = crate::algorithms::text_layout_paragraph::
                build_segments_from_text(&e.tspans, &content_str, e.is_area_text());
            let layout = crate::algorithms::text_layout::layout_with_paragraphs(
                &content_str,
                max_w,
                leading_px,
                &segments,
                measure.as_ref(),
            );
            let chars: Vec<char> = content_str.chars().collect();
            let has_underline = e.text_decoration.split_whitespace().any(|t| t == "underline");
            let has_strike = e.text_decoration.split_whitespace().any(|t| t == "line-through");
            for line in &layout.lines {
                let s: String = chars[line.start..line.end].iter().collect();
                let s = s.trim_end_matches('\n');
                let baseline = e.y + line.baseline_y + y_shift;
                // Per-line x shift comes from the first glyph's x,
                // which the paragraph-aware layout already shifted
                // by left_indent + first_line_indent + alignment.
                let line_x_shift = layout.glyphs
                    .get(line.glyph_start)
                    .map(|g| g.x)
                    .unwrap_or(0.0);
                let line_x = e.x + line_x_shift;
                // When the layout stretched glue widths (justify), the
                // single fill_text path would render each line with the
                // canvas's *natural* inter-word advance and the result
                // would look left-flush. Detect that by comparing the
                // line's last visible glyph's right against the natural
                // width of the line text — any non-trivial gap means a
                // glue was stretched and we must position words
                // individually using the layout's per-glyph x.
                let line_glyphs = &layout.glyphs[line.glyph_start..line.glyph_end];
                let last_visible_right = line_glyphs.iter()
                    .filter(|g| !g.is_trailing_space)
                    .map(|g| g.right)
                    .fold(0.0f64, f64::max);
                let first_visible_x = line_glyphs.iter()
                    .filter(|g| !g.is_trailing_space)
                    .map(|g| g.x)
                    .fold(f64::INFINITY, f64::min);
                let natural_w = measure(s);
                let layout_w = (last_visible_right - first_visible_x).max(0.0);
                let glues_stretched = layout_w > natural_w + 0.5;
                if rotate_rad == 0.0 && !glues_stretched {
                    // Fast path: single fill_text per line. The CSS
                    // letterSpacing property set earlier handles the
                    // inter-glyph advance.
                    ctx.fill_text(s, line_x, baseline).ok();
                } else if rotate_rad == 0.0 {
                    // Justified line: render word-by-word so each
                    // word lands at the x the composer computed
                    // (with stretched glue between words).
                    let chars_v: Vec<char> = s.chars().collect();
                    let mut word_buf = String::new();
                    let mut word_x = 0.0f64;
                    let mut in_word = false;
                    for (i, g) in line_glyphs.iter().enumerate() {
                        let ch = chars_v.get(i).copied();
                        let is_ws = ch.map_or(true, |c| c.is_whitespace());
                        if !is_ws && !g.is_trailing_space {
                            if !in_word {
                                word_x = e.x + g.x;
                                in_word = true;
                                word_buf.clear();
                            }
                            if let Some(c) = ch { word_buf.push(c); }
                        } else if in_word {
                            ctx.fill_text(&word_buf, word_x, baseline).ok();
                            in_word = false;
                        }
                    }
                    if in_word {
                        ctx.fill_text(&word_buf, word_x, baseline).ok();
                    }
                }
                if line.trailing_hyphen && rotate_rad == 0.0 {
                    // Hyphenation broke a word at end of line. The
                    // composer reserved space for the hyphen but the
                    // source content has no hyphen char, so the
                    // renderer must draw the glyph itself. The
                    // synthetic hyphen sits at the line's rightmost
                    // glyph x — derive it from the last glyph (which
                    // the composer emitted with width = hyphen_w).
                    let hyph_x = line_glyphs.iter()
                        .filter(|g| !g.is_trailing_space)
                        .last()
                        .map(|g| e.x + g.x)
                        .unwrap_or(line_x);
                    ctx.fill_text("-", hyph_x, baseline).ok();
                }
                if rotate_rad != 0.0 {
                    // Per-glyph rotation: each glyph rotates around
                    // its own (cx, baseline). fill_text takes only a
                    // whole string, so draw one char at a time and
                    // advance cx manually. letter_spacing is folded
                    // into the advance the same way the fast path
                    // relies on CSS letterSpacing.
                    let mut cx = line_x;
                    for ch in s.chars() {
                        let ch_str = ch.to_string();
                        // The glyph's own frame: the block ends the guarded
                        // span exactly where the manual restore() stood, so
                        // the advance below is measured in the parent frame
                        // (see CtxSaveGuard).
                        {
                            let _ctx_guard = CtxSaveGuard::new(ctx);
                            ctx.translate(cx, baseline).ok();
                            ctx.rotate(rotate_rad).ok();
                            ctx.fill_text(&ch_str, 0.0, 0.0).ok();
                        }
                        cx += measure(&ch_str) + ls_px;
                    }
                }
                if has_underline || has_strike {
                    let w = measure(s);
                    draw_text_decorations(
                        ctx, line_x, baseline, w, effective_fs,
                        has_underline, has_strike, e.fill.as_ref(),
                    );
                }
            }
            // Phase 6: list markers. Walk the segments and draw each
            // active list paragraph's marker glyph at x = element.x +
            // segment.left_indent, baseline = first-line baseline.
            // Counter values are computed once across all segments so
            // the run rule (consecutive same-style num-* paragraphs
            // count up; anything else resets) holds across the
            // element's whole content.
            if !segments.is_empty() {
                // A list-style segment may span multiple paragraphs
                // (the user typed "a\nb\nc" then clicked bullets — the
                // model has one wrapper covering all three lines). The
                // bullet must appear on every paragraph, so walk the
                // layout's lines and treat any line whose predecessor
                // ended at a hard break ('\n') as a sub-paragraph
                // start. Counter values follow the §Counter run rule
                // across the flattened sub-paragraph sequence.
                let owning_seg_for_line = |line_start: usize| -> Option<usize> {
                    segments.iter().position(|s|
                        s.char_start <= line_start && line_start < s.char_end)
                };
                #[derive(Clone)]
                struct SubPara { line_idx: usize, style: Option<String>, left_indent: f64 }
                let mut sub_paras: Vec<SubPara> = Vec::new();
                let mut prev_hard_break = true;
                for (li, line) in layout.lines.iter().enumerate() {
                    if prev_hard_break {
                        let (style, left_indent) = match owning_seg_for_line(line.start) {
                            Some(si) => (segments[si].list_style.clone(), segments[si].left_indent),
                            None => (None, 0.0),
                        };
                        sub_paras.push(SubPara { line_idx: li, style, left_indent });
                    }
                    prev_hard_break = line.hard_break;
                }
                // Per-style counter run: consecutive same num-* style
                // sub-paragraphs continue counting; a different style
                // (or bullet, or none) breaks the run.
                let mut counters: Vec<usize> = Vec::with_capacity(sub_paras.len());
                let mut prev_num: Option<String> = None;
                let mut current = 0usize;
                for sp in &sub_paras {
                    match sp.style.as_deref() {
                        Some(s) if s.starts_with("num-") => {
                            if prev_num.as_deref() == Some(s) {
                                current += 1;
                            } else {
                                current = 1;
                            }
                            counters.push(current);
                            prev_num = Some(s.to_string());
                        }
                        _ => {
                            counters.push(0);
                            prev_num = None;
                            current = 0;
                        }
                    }
                }
                for (sp, counter) in sub_paras.iter().zip(counters.iter()) {
                    let style = match &sp.style {
                        Some(s) if !s.is_empty() => s,
                        _ => continue,
                    };
                    let marker = crate::algorithms::text_layout_paragraph::
                        marker_text(style, *counter);
                    if marker.is_empty() { continue; }
                    let line = &layout.lines[sp.line_idx];
                    let baseline = e.y + line.baseline_y + y_shift;
                    let marker_x = e.x + sp.left_indent;
                    ctx.fill_text(&marker, marker_x, baseline).ok();
                }
            }
            // Reset letterSpacing so subsequent text elements without
            // the attribute draw without inheriting this one's value.
            if ls_px != 0.0 {
                let _ = js_sys::Reflect::set(
                    ctx,
                    &js_sys::JsString::from("letterSpacing"),
                    &js_sys::JsString::from("0px"),
                );
            }
            // The v/h-scale frame pops here, via `_scale_guard`'s Drop.
            } // end else (is_flat)
        }
        Element::TextPath(e) => {
            // Draw the path as a faint guide line
            ctx.set_stroke_style_str("rgba(180,180,180,0.4)");
            ctx.set_line_width(1.0);
            ctx.begin_path();
            build_path(ctx, &e.d);
            ctx.stroke();

            // Draw text along the path
            let content_str = e.content();
            if !content_str.is_empty() && !e.d.is_empty() {
                let fill_op = apply_fill(ctx, e.fill.as_ref(), None, (0.0, 0.0, 0.0, 0.0));
                ctx.set_global_alpha(base_alpha * fill_op);
                let font = format!(
                    "{} {} {}px {}",
                    e.font_style, e.font_weight, e.font_size, e.font_family
                );
                ctx.set_font(&font);

                // Flatten the path and measure total length
                let pts = flatten_path_commands(&e.d);
                let mut lengths = vec![0.0_f64];
                for i in 1..pts.len() {
                    let dx = pts[i].0 - pts[i - 1].0;
                    let dy = pts[i].1 - pts[i - 1].1;
                    lengths.push(lengths[i - 1] + (dx * dx + dy * dy).sqrt());
                }
                let total = *lengths.last().unwrap_or(&0.0);
                if total > 0.0 {
                    let mut offset = e.start_offset * total;
                    for ch in content_str.chars() {
                        let ch_str = ch.to_string();
                        let ch_width = ctx.measure_text(&ch_str).map(|m: web_sys::TextMetrics| m.width()).unwrap_or(8.0);
                        let t = (offset + ch_width / 2.0) / total;
                        if t > 1.0 { break; }
                        if t >= 0.0 {
                            // Get point and tangent at offset
                            let (px, py) = path_point_at_offset(&e.d, t);
                            let t2 = ((offset + ch_width) / total).min(1.0);
                            let (px2, py2) = path_point_at_offset(&e.d, t2);
                            let angle = (py2 - py).atan2(px2 - px);

                            // The glyph's frame on the path; popped at the
                            // end of this branch (see CtxSaveGuard).
                            let _ctx_guard = CtxSaveGuard::new(ctx);
                            ctx.translate(px, py).ok();
                            ctx.rotate(angle).ok();
                            ctx.fill_text(&ch_str, -ch_width / 2.0, e.font_size * 0.35).ok();
                        }
                        offset += ch_width;
                    }
                }
            }
        }
        Element::Group(g) => {
            // Cap each child's effective visibility by our own
            // effective visibility (which already incorporates our
            // ancestor's cap). Thread the accumulated element-transform
            // scale so a stroked shape inside this (possibly scaled) group
            // is counter-scaled by the full ancestor chain.
            for child in &g.children {
                draw_element_scaled(ctx, child, effective, precision, elem_scale);
            }
        }
        Element::Layer(l) => {
            for child in &l.children {
                draw_element_scaled(ctx, child, effective, precision, elem_scale);
            }
        }
        Element::Live(v) => {
            // Evaluate the live element, resolving references against the
            // render-scoped index. The cycle guard is a fresh local per
            // top-level evaluate. Per variant we also pick the paint: a
            // reference inherits the resolved target's paint when its own is
            // unset (Fork F3).
            let mut visiting = crate::geometry::live::VisitSet::new();
            let (ps, live_fill, live_stroke) = match v {
                crate::geometry::live::LiveVariant::CompoundShape(cs) => (
                    cs.evaluate_with(precision, &RenderResolver, &mut visiting),
                    cs.fill.clone(),
                    cs.stroke.clone(),
                ),
                crate::geometry::live::LiveVariant::Reference(r) => {
                    let ps = r.evaluate_with(precision, &RenderResolver, &mut visiting);
                    let target = RenderResolver.resolve(&r.target);
                    let fill = r.fill.clone()
                        .or_else(|| target.as_ref().and_then(|t| t.fill().cloned()));
                    let stroke = r.stroke.clone()
                        .or_else(|| target.as_ref().and_then(|t| t.stroke().cloned()));
                    (ps, fill, stroke)
                }
                // A recorded element renders its replayed (derived) geometry,
                // resolved against its inputs (RECORDED_ELEMENTS.md).
                crate::geometry::live::LiveVariant::Recorded(rec) => (
                    rec.evaluate_with(precision, &RenderResolver, &mut visiting),
                    rec.fill.clone(),
                    rec.stroke.clone(),
                ),
                // A generated element renders its concept's evaluated geometry,
                // resolving the concept via the resolver's registry (CONCEPTS.md).
                crate::geometry::live::LiveVariant::Generated(ge) => (
                    ge.evaluate_with(precision, &RenderResolver, &mut visiting),
                    ge.fill.clone(),
                    ge.stroke.clone(),
                ),
            };
            let (mut fill_op, mut stroke_op, mut stroke_align) =
                (1.0, 1.0, StrokeAlign::Center);
            if outline {
                apply_outline_style(ctx);
            } else {
                fill_op = apply_fill(ctx, live_fill.as_ref(), None, (0.0, 0.0, 0.0, 0.0));
                (stroke_op, stroke_align) = apply_stroke(ctx, live_stroke.as_ref());
            }
            if ps.iter().any(|r| r.len() >= 2) {
                ctx.begin_path();
                for ring in &ps {
                    if ring.len() < 2 { continue; }
                    ctx.move_to(ring[0].0, ring[0].1);
                    for &(x, y) in &ring[1..] {
                        ctx.line_to(x, y);
                    }
                    ctx.close_path();
                }
                if !outline && live_fill.is_some() {
                    ctx.set_global_alpha(base_alpha * fill_op);
                    ctx.fill();
                }
                if outline || live_stroke.is_some() {
                    ctx.set_global_alpha(base_alpha * stroke_op);
                    stroke_aligned(ctx, stroke_align);
                }
            }
        }
    }
    // restore happens via _ctx_guard's Drop.
}

// ---------------------------------------------------------------------------
// Draw selection overlays
// ---------------------------------------------------------------------------

/// Trace the given element's geometry as a sub-path on `ctx` without
/// filling or stroking. Used by `draw_selection_overlays` to stroke
/// Draw the underline and/or strikethrough lines for a text run.
/// Called from Text rendering when `text_decoration` includes either
/// token. Positions follow CSS-ish conventions: underline sits at
/// ~5% of the font size below the baseline, strike-through at roughly
/// the x-height (about 35% above the baseline). Line thickness is a
/// fixed fraction of the font size so it scales with the text.
/// Draw a Text element's tspans in sequence on a shared baseline,
/// each using its effective font (override || parent-element fallback)
/// and its effective text-decoration. Wraps the minimum subset of
/// TSPAN.md's "Rendering" section: different fonts and decorations
/// across spans in the same Text. Omits per-tspan baseline-shift,
/// transform, rotate, dx, small-caps, and multi-line wrapping —
/// those still collapse to the element-wide defaults for now.
fn draw_segmented_text(
    ctx: &CanvasRenderingContext2d,
    e: &crate::geometry::element::TextElem,
) {
    // Parent fallbacks for each tspan field.
    let parent_bold = e.font_weight == "bold";
    let parent_italic = e.font_style == "italic" || e.font_style == "oblique";
    // Parent decoration tokens — used when the tspan doesn't override.
    let parent_decor: Vec<&str> = e.text_decoration
        .split_whitespace()
        .filter(|t| !t.is_empty() && *t != "none")
        .collect();

    // The baseline sits at the first visual line: element y + 0.8 *
    // font_size. Segmented rendering is one-line only for now.
    let baseline = e.y + e.font_size * 0.8;
    let mut cx = e.x;

    for t in &e.tspans {
        if t.content.is_empty() {
            continue;
        }
        let eff_family = t.font_family.as_deref().unwrap_or(&e.font_family);
        let eff_size = t.font_size.unwrap_or(e.font_size);
        let eff_weight = match t.font_weight.as_deref() {
            Some(w) => w,
            None => if parent_bold { "bold" } else { "normal" },
        };
        let eff_style = match t.font_style.as_deref() {
            Some(s) => s,
            None => if parent_italic { "italic" } else { "normal" },
        };
        let font = format!("{} {} {}px {}",
            eff_style, eff_weight, eff_size, eff_family);
        ctx.set_font(&font);

        // Per-tspan positioning: dx is a leading-edge horizontal
        // nudge in em (so a fresh tspan advance contribution);
        // baseline_shift in pt offsets the baseline (sign convention
        // mirrors CSS / TSPAN.md: + is up — negative y in canvas).
        // rotate / transform wrap the tspan draw around its starting
        // baseline position. All compose on top of the shared
        // baseline from the parent Text.
        let dx_px = t.dx.unwrap_or(0.0) * eff_size;
        cx += dx_px;
        let baseline_shift = t.baseline_shift.unwrap_or(0.0);
        let tspan_baseline = baseline - baseline_shift;
        let rotate_deg = t.rotate.unwrap_or(0.0);
        let rotate_rad = rotate_deg.to_radians();
        let has_transform = t.transform.is_some();
        let has_rotate = rotate_rad != 0.0;

        // Conditional guarded save: `Some` only when this tspan needs its own
        // frame. Dropped explicitly below, at the site of the paired manual
        // restore() (see CtxSaveGuard).
        let tspan_guard = if has_rotate || has_transform {
            let guard = CtxSaveGuard::new(ctx);
            ctx.translate(cx, tspan_baseline).ok();
            if let Some(tr) = &t.transform {
                ctx.transform(tr.a, tr.b, tr.c, tr.d, tr.e, tr.f).ok();
            }
            if has_rotate {
                ctx.rotate(rotate_rad).ok();
            }
            ctx.fill_text(&t.content, 0.0, 0.0).ok();
            Some(guard)
        } else {
            ctx.fill_text(&t.content, cx, tspan_baseline).ok();
            None
        };

        // Effective decoration: Some([..]) overrides parent (empty
        // list = explicit no-decoration); None inherits parent tokens.
        let (has_underline, has_strike) = match t.text_decoration.as_deref() {
            Some(members) => (
                members.iter().any(|m| m == "underline"),
                members.iter().any(|m| m == "line-through"),
            ),
            None => (
                parent_decor.iter().any(|m| *m == "underline"),
                parent_decor.iter().any(|m| *m == "line-through"),
            ),
        };
        let measure = crate::tools::text_measure::make_measurer(&font, eff_size);
        let w = measure(&t.content);
        if has_underline || has_strike {
            if has_rotate || has_transform {
                // Decorations draw in the tspan's local frame so
                // they rotate / transform with the glyphs.
                draw_text_decorations(
                    ctx, 0.0, 0.0, w, eff_size,
                    has_underline, has_strike, e.fill.as_ref(),
                );
            } else {
                draw_text_decorations(
                    ctx, cx, tspan_baseline, w, eff_size,
                    has_underline, has_strike, e.fill.as_ref(),
                );
            }
        }
        // Pop the tspan frame here rather than at the loop-body end, so the
        // guarded span is exactly the former save/restore span.
        drop(tspan_guard);
        cx += w;
    }
}

fn draw_text_decorations(
    ctx: &CanvasRenderingContext2d,
    x: f64,
    baseline_y: f64,
    width: f64,
    font_size: f64,
    underline: bool,
    strike: bool,
    fill: Option<&Fill>,
) {
    let color = match fill {
        Some(f) => css_color(&f.color),
        None => "currentColor".to_string(),
    };
    let thickness = (font_size * 0.07).max(1.0);
    ctx.set_stroke_style_str(&color);
    ctx.set_line_width(thickness);
    if underline {
        let y = baseline_y + font_size * 0.12;
        ctx.begin_path();
        ctx.move_to(x, y);
        ctx.line_to(x + width, y);
        ctx.stroke();
    }
    if strike {
        let y = baseline_y - font_size * 0.3;
        ctx.begin_path();
        ctx.move_to(x, y);
        ctx.line_to(x + width, y);
        ctx.stroke();
    }
}

/// the element's path in the selection color.
///
/// Text, TextPath, Group, and Layer are not traced here — they use a
/// bounding-box overlay (Text/TextPath) or rely on their descendants'
/// individual highlights (Group/Layer).
fn trace_element_path(ctx: &CanvasRenderingContext2d, elem: &Element) {
    match elem {
        Element::Line(e) => {
            ctx.move_to(e.x1, e.y1);
            ctx.line_to(e.x2, e.y2);
        }
        Element::Rect(e) => {
            if e.rx > 0.0 || e.ry > 0.0 {
                let rx = e.rx.max(0.0).min(e.width / 2.0);
                let ry = e.ry.max(0.0).min(e.height / 2.0);
                let x = e.x;
                let y = e.y;
                let w = e.width;
                let h = e.height;
                ctx.move_to(x + rx, y);
                ctx.line_to(x + w - rx, y);
                ctx.quadratic_curve_to(x + w, y, x + w, y + ry);
                ctx.line_to(x + w, y + h - ry);
                ctx.quadratic_curve_to(x + w, y + h, x + w - rx, y + h);
                ctx.line_to(x + rx, y + h);
                ctx.quadratic_curve_to(x, y + h, x, y + h - ry);
                ctx.line_to(x, y + ry);
                ctx.quadratic_curve_to(x, y, x + rx, y);
                ctx.close_path();
            } else {
                ctx.rect(e.x, e.y, e.width, e.height);
            }
        }
        Element::Ellipse(e) => {
            ctx.move_to(e.cx + e.rx, e.cy);
            ctx.ellipse(e.cx, e.cy, e.rx, e.ry, 0.0, 0.0, std::f64::consts::TAU)
                .ok();
        }
        Element::Polyline(e) => {
            if !e.points.is_empty() {
                ctx.move_to(e.points[0].0, e.points[0].1);
                for &(x, y) in &e.points[1..] {
                    ctx.line_to(x, y);
                }
            }
        }
        Element::Polygon(e) => {
            if !e.points.is_empty() {
                ctx.move_to(e.points[0].0, e.points[0].1);
                for &(x, y) in &e.points[1..] {
                    ctx.line_to(x, y);
                }
                ctx.close_path();
            }
        }
        Element::Path(e) => {
            build_path(ctx, &e.d);
        }
        Element::Text(_)
        | Element::TextPath(_)
        | Element::Group(_)
        | Element::Layer(_) => {
            // Handled separately via bounding-box overlays or
            // descendant highlights.
        }
        Element::Live(v) => {
            let mut visiting = crate::geometry::live::VisitSet::new();
            let ps = match v {
                crate::geometry::live::LiveVariant::CompoundShape(cs) => cs.evaluate_with(
                    crate::geometry::live::DEFAULT_PRECISION, &RenderResolver, &mut visiting),
                crate::geometry::live::LiveVariant::Reference(r) => r.evaluate_with(
                    crate::geometry::live::DEFAULT_PRECISION, &RenderResolver, &mut visiting),
                crate::geometry::live::LiveVariant::Recorded(rec) => rec.evaluate_with(
                    crate::geometry::live::DEFAULT_PRECISION, &RenderResolver, &mut visiting),
                crate::geometry::live::LiveVariant::Generated(ge) => ge.evaluate_with(
                    crate::geometry::live::DEFAULT_PRECISION, &RenderResolver, &mut visiting),
            };
            for ring in &ps {
                if ring.len() < 2 { continue; }
                ctx.move_to(ring[0].0, ring[0].1);
                for &(x, y) in &ring[1..] {
                    ctx.line_to(x, y);
                }
                ctx.close_path();
            }
        }
    }
}

/// Document-space control-point handle rects `(x, y, w, h)` for the element
/// at `path`.
///
/// Each rect is centered at the element-transformed control point and is a
/// constant `HANDLE_DRAW_SIZE` square, so an element's transform MOVES the
/// handles but never SCALES the handle glyphs (they stay a fixed grab size).
/// Returns `[]` for containers (Group / Layer) and Text / TextPath, which
/// carry no control-point squares (mirrors the in-transform overlay draw).
/// The caller draws these under the VIEW (pan/zoom) transform only, NOT the
/// element transform. Mirrors the Python reference `selection_handle_rects`.
pub fn selection_handle_rects(
    doc: &Document,
    path: &[usize],
) -> Vec<(f64, f64, f64, f64)> {
    if path.is_empty() {
        return Vec::new();
    }
    // Resolve the element + collect ancestor transforms (outermost first):
    // the root layer, then each intervening group on the path.
    let mut node = match doc.layers.get(path[0]) {
        Some(n) => n,
        None => return Vec::new(),
    };
    let mut ancestors: Vec<Option<Transform>> = Vec::new();
    if path.len() > 1 {
        ancestors.push(node.transform().copied()); // layer
        for &idx in &path[1..path.len() - 1] {
            node = match node.children().and_then(|c| c.get(idx)) {
                Some(n) => n,
                None => return Vec::new(),
            };
            ancestors.push(node.transform().copied());
        }
        node = match node.children().and_then(|c| c.get(path[path.len() - 1])) {
            Some(n) => n,
            None => return Vec::new(),
        };
    }
    let elem = node;
    if matches!(
        elem,
        Element::Text(_) | Element::TextPath(_) | Element::Group(_) | Element::Layer(_)
    ) {
        return Vec::new();
    }
    // Apply transforms innermost-first: the element's own transform, then each
    // ancestor outward (layer last) — matching the rendered combined CTM.
    let mut chain: Vec<Transform> = Vec::new();
    if let Some(t) = elem.transform() {
        chain.push(*t);
    }
    for t in ancestors.iter().rev() {
        if let Some(t) = t {
            chain.push(*t);
        }
    }
    let half = HANDLE_DRAW_SIZE / 2.0;
    // RESOLVED: a symbol instance measures its TARGET, so the resolver-less
    // `control_points` collapsed its four corners onto the document origin —
    // the selection BOX resolved (it goes through `element_evaluated_bbox`)
    // while its handles sat in the corner of the canvas.
    let index = crate::document::id_index::rebuild_id_index(doc);
    let resolver = crate::document::id_index::IndexResolver(&index);
    crate::geometry::element::control_points_with(elem, &resolver)
        .into_iter()
        .map(|(mut px, mut py)| {
            for t in &chain {
                let (nx, ny) = t.apply_point(px, py);
                px = nx;
                py = ny;
            }
            (px - half, py - half, HANDLE_DRAW_SIZE, HANDLE_DRAW_SIZE)
        })
        .collect()
}

// The transform-aware (EVALUATED) bboxes moved to the NATIVE module
// `document::evaluated_bounds` so the algorithm_roundtrip binary — built
// without feature="web", which this whole module is behind — can drive
// them, closing the CORPUS_CENSUS.md 5.1 element_bounds hole. Re-exported
// here so `canvas::render::selection_evaluated_bounds` call sites and the
// tests below are unchanged.
pub use crate::document::evaluated_bounds::selection_evaluated_bounds;

/// Combined transform SCALE of the element at `path` — the geometric mean of
/// the linear part, `sqrt(|det|)`, multiplied over the element's own transform
/// and every ancestor (layer/group) transform. `det = a*d - b*c`.
///
/// The selection OUTLINE trace is drawn UNDER the element transform; dividing
/// its fixed pen width by this factor cancels the element transform's scaling,
/// so it renders at a constant size (still scaled by zoom, like the handle
/// squares). Returns `1.0` when there is no transform.
///
/// `det` is multiplicative, so the chain order does not matter — we just
/// multiply `sqrt(|det|)` of each non-identity transform on the path. Exact for
/// uniform scale, geometric-mean (acceptable) under non-uniform/shear. Mirrors
/// the Python reference `selection_outline_scale`.
pub fn selection_outline_scale(doc: &Document, path: &[usize]) -> f64 {
    if path.is_empty() {
        return 1.0;
    }
    let mut node = match doc.layers.get(path[0]) {
        Some(n) => n,
        None => return 1.0,
    };
    // Collect the element's own transform plus every ancestor (layer/group)
    // transform on the path, mirroring the Python walk.
    let mut transforms: Vec<Option<Transform>> = Vec::new();
    if path.len() > 1 {
        transforms.push(node.transform().copied()); // layer
        for &idx in &path[1..path.len() - 1] {
            node = match node.children().and_then(|c| c.get(idx)) {
                Some(n) => n,
                None => return 1.0,
            };
            transforms.push(node.transform().copied());
        }
        node = match node.children().and_then(|c| c.get(path[path.len() - 1])) {
            Some(n) => n,
            None => return 1.0,
        };
    }
    transforms.push(node.transform().copied()); // the element itself
    let mut scale = 1.0_f64;
    for t in transforms.into_iter().flatten() {
        let det = (t.a * t.d - t.b * t.c).abs();
        if det > 0.0 {
            scale *= det.sqrt();
        }
    }
    scale
}

fn draw_selection_overlays(ctx: &CanvasRenderingContext2d, doc: &Document) {
    let sel_color = "rgba(0, 120, 215, 0.9)";
    ctx.set_stroke_style_str(sel_color);
    ctx.set_line_width(1.0);

    // Built once for the whole overlay pass: a container's outline is the union
    // of its children, and a symbol instance child measures its TARGET. The
    // resolver-less union swallows the instance's zero box as a phantom point
    // AT THE ORIGIN, so selecting a group that holds one drew its box back
    // across empty canvas to (0,0).
    let sel_index = crate::document::id_index::rebuild_id_index(doc);
    let sel_resolver = crate::document::id_index::IndexResolver(&sel_index);

    for es in &doc.selection {
        let elem = match doc.get_element(&es.path) {
            Some(e) => e,
            None => continue,
        };

        // Apply the element's transform (translation from align ops,
        // future rotate/scale, etc.) so the overlay tracks the
        // rendered element. The guarded block scopes that transform to the
        // outline trace: the handle pass below MUST run in the popped state
        // (view transform only), so the block ends exactly where the manual
        // restore() stood (see CtxSaveGuard).
        {
            let _ctx_guard = CtxSaveGuard::new(ctx);
            apply_transform(ctx, elem.transform());

            // Counter-scale the fixed outline pen width by the element
            // transform's scale (selection_outline_scale) so the outline trace
            // — drawn UNDER that transform — renders at a constant width
            // regardless of the element's scale (it stays zoom-scaled, like
            // the handle squares).
            let outline_scale = selection_outline_scale(doc, &es.path);
            let inv = if outline_scale > 1e-6 { 1.0 / outline_scale } else { 1.0 };
            ctx.set_line_width(inv);

            // Text and TextPath get a bounding-box highlight instead of
            // a path trace. For area text the bbox aligns with the area
            // (that's what `bounds()` returns); for point text it wraps
            // the drawn glyphs; for TextPath it wraps the path the text
            // follows.
            let is_text_like = matches!(elem, Element::Text(_) | Element::TextPath(_));
            // Containers (Group / Layer) are picked as whole elements by
            // the Selection tool's hit_test (which stops at direct layer
            // children). Per the vector-illustration convention, a selected
            // Group is shown as a single bbox around its contents — not as
            // individual descendant outlines — so we render the
            // children-union bounds here.
            let is_container = matches!(elem, Element::Group(_) | Element::Layer(_));

            if is_container {
                if let Some((bx, by, bw, bh)) =
                    crate::geometry::element::resolved_bounds_with(
                        elem, &sel_resolver, Element::bounds)
                    && bw > 0.0
                    && bh > 0.0
                {
                    ctx.stroke_rect(bx, by, bw, bh);
                }
            } else {
                // Text and TextPath show a bbox + corner handles so the
                // user can grab and resize/move the text frame; other
                // elements stroke their own path. ``control_points``
                // returns the 4 bbox corners for text elements (default
                // fallback) so the same handle-drawing loop below works
                // unchanged.
                if is_text_like {
                    let (bx, by, bw, bh) = elem.bounds();
                    if bw > 0.0 && bh > 0.0 {
                        ctx.stroke_rect(bx, by, bw, bh);
                    }
                } else {
                    ctx.begin_path();
                    trace_element_path(ctx, elem);
                    ctx.stroke();
                }

                // NOTE: the control-point handle SQUARES are intentionally NOT
                // drawn here. They are drawn below via `selection_handle_rects`
                // at a FIXED screen size under the view (pan/zoom) transform
                // only — the element transform was restored — so an element's
                // transform moves them but never scales the glyphs. The
                // outline trace above stays under the element transform (it
                // traces the geometry).
            }
        }

        // Control-point handles: FIXED size at element-transformed positions,
        // drawn under the VIEW (pan/zoom) transform only — the element
        // transform was restored above — so the element's transform moves the
        // handles but never scales the glyphs. A selected CP (per the
        // `Partial` set, or any CP when kind is `All`) gets the solid blue
        // fill; others get white.
        //
        // Reset the line width to the fixed 1.0 px: the outline pass above may
        // have set it to `inv` (counter-scaled), but the handle SQUARES are a
        // separate fixed-size pass (drawn after `restore`, under the view
        // transform only) and must NOT be counter-scaled by the element scale.
        ctx.set_line_width(1.0);
        ctx.set_stroke_style_str(sel_color);
        for (i, (hx, hy, hw, hh)) in
            selection_handle_rects(doc, &es.path).into_iter().enumerate()
        {
            if es.kind.contains(i) {
                ctx.set_fill_style_str(sel_color);
            } else {
                ctx.set_fill_style_str("white");
            }
            ctx.fill_rect(hx, hy, hw, hh);
            ctx.stroke_rect(hx, hy, hw, hh);
        }
    }
}

// ---------------------------------------------------------------------------
// Artboard rendering (ARTBOARDS.md §Canvas appearance)
// ---------------------------------------------------------------------------
//
// Z-order around the existing element / selection passes:
//
//   1. Canvas background (white fill in `render()`)
//   2. draw_artboard_fills       — per artboard, list order
//   3. (element tree — unchanged)
//   4. draw_fade_overlay         — dims off-artboard regions (phase-E)
//   5. draw_artboard_borders     — thin default borders
//   5b. draw_bleed_guides        — red dashed rect, when bleed != 0
//   6. draw_artboard_accent      — 2px outline for panel-selected
//   7. draw_artboard_labels      — "N  Name" above top-left
//   8. draw_artboard_display_marks — center mark / cross hairs / safe areas
//   9. draw_selection_overlays   — unchanged
//
// Phase-D first pass: borders / accent / label / marks are drawn at
// 1 device-pixel at the current canvas transform — matching the
// existing selection-overlay idiom. Full zoom-independent screen-
// pixel sizing waits on passing the canvas scale through `render()`.

const ARTBOARD_BORDER_COLOR: &str = "rgb(48,48,48)";
const ARTBOARD_ACCENT_COLOR: &str = "rgba(0, 120, 215, 0.95)";
const ARTBOARD_MARK_COLOR: &str = "rgb(150,150,150)";
const ARTBOARD_LABEL_COLOR: &str = "rgb(200,200,200)";

fn artboard_fill_css(fill: &ArtboardFill) -> Option<String> {
    match fill {
        // Default-Transparent artboards visually appear white over
        // the gray pasteboard — matching the convention in every
        // vector-illustration app. A truly see-through artboard
        // isn't a real-world use case here.
        ArtboardFill::Transparent => Some("#ffffff".to_string()),
        ArtboardFill::Color(hex) => Some(hex.clone()),
    }
}

fn draw_artboard_fills(ctx: &CanvasRenderingContext2d, doc: &Document) {
    for ab in &doc.artboards {
        if let Some(css) = artboard_fill_css(&ab.fill) {
            ctx.set_fill_style_str(&css);
            ctx.fill_rect(ab.x, ab.y, ab.width, ab.height);
        }
        // Transparent: no fill, canvas shows through.
    }
}

/// Z-layer 4: fade overlay — ARTBOARDS.md §Canvas appearance.
///
/// Deliberate no-op, matching the Swift port's `drawFadeOverlay`
/// (`JasSwift/Sources/Canvas/CanvasSubwindow.swift`): the gray pasteboard
/// plus opaque-white artboard fills already give the "outside the printable
/// area" contrast the option asks for, and the only implementation tried —
/// fill the canvas with 50% gray, then punch the artboards out with the
/// `destination-out` composite — was actively wrong. destination-out writes
/// alpha=0, so it holed the white artboard fills and showed the canvas
/// element's own background through the artboards (the "white canvas → dark
/// artboard" smoke regression in both ports).
///
/// The z-order slot and the call are kept so the documented layer stays
/// visible and `fade_region_outside_artboard` has somewhere to land. That
/// option is real document state: `doc.set_artboard_options_field` writes it
/// (`op_apply.rs`), so it is op-logged and undoable, and `test_json.rs`
/// carries it in the cross-language document serialization. It does NOT
/// round-trip through SVG — `geometry/svg.rs` resets `artboard_options` to
/// defaults on parse, since SVG has no artboards concept. A real
/// implementation must be non-destructive: darken ONLY the pasteboard
/// region, e.g. fill an even-odd path of the canvas rect minus every
/// artboard rect, or composite a separate raster mask built before the
/// artboard fill pass. Both ports stay no-ops until then, so the display
/// lists match. Spec: ARTBOARDS.md §Document-global display toggles, which
/// records the deferral rather than promising the mask.
fn draw_fade_overlay(
    _ctx: &CanvasRenderingContext2d,
    _doc: &Document,
    _width: f64,
    _height: f64,
) {
}

fn draw_artboard_borders(ctx: &CanvasRenderingContext2d, doc: &Document) {
    ctx.set_stroke_style_str(ARTBOARD_BORDER_COLOR);
    ctx.set_line_width(1.0);
    for ab in &doc.artboards {
        ctx.stroke_rect(ab.x, ab.y, ab.width, ab.height);
    }
}

const BLEED_GUIDE_COLOR: &str = "rgb(229,0,0)";
const BLEED_GUIDE_DASH: [f64; 2] = [4.0, 4.0];

/// Compute the on-canvas bleed guide rectangle for one artboard, in
/// document points: `(x, y, w, h)` extended outward from the artboard
/// by the per-side bleed values. Returns `None` when all four bleeds
/// are zero (the no-bleed case is the default and elides the guide
/// entirely).
pub fn bleed_rect_for_artboard(
    ab: &crate::document::artboard::Artboard,
    setup: &crate::document::document_setup::DocumentSetup,
) -> Option<(f64, f64, f64, f64)> {
    if setup.bleed_top == 0.0
        && setup.bleed_right == 0.0
        && setup.bleed_bottom == 0.0
        && setup.bleed_left == 0.0
    {
        return None;
    }
    Some((
        ab.x - setup.bleed_left,
        ab.y - setup.bleed_top,
        ab.width + setup.bleed_left + setup.bleed_right,
        ab.height + setup.bleed_top + setup.bleed_bottom,
    ))
}

fn draw_bleed_guides(ctx: &CanvasRenderingContext2d, doc: &Document) {
    if doc.document_setup.bleed_top == 0.0
        && doc.document_setup.bleed_right == 0.0
        && doc.document_setup.bleed_bottom == 0.0
        && doc.document_setup.bleed_left == 0.0
    {
        return;
    }
    // Guarded: the dash pattern + pen state pop when this function returns,
    // on every path (see CtxSaveGuard).
    let _ctx_guard = CtxSaveGuard::new(ctx);
    ctx.set_stroke_style_str(BLEED_GUIDE_COLOR);
    ctx.set_line_width(1.0);
    let dash = js_sys::Array::new();
    dash.push(&wasm_bindgen::JsValue::from_f64(BLEED_GUIDE_DASH[0]));
    dash.push(&wasm_bindgen::JsValue::from_f64(BLEED_GUIDE_DASH[1]));
    let _ = ctx.set_line_dash(&dash);
    for ab in &doc.artboards {
        if let Some((x, y, w, h)) = bleed_rect_for_artboard(ab, &doc.document_setup) {
            ctx.stroke_rect(x, y, w, h);
        }
    }
    ctx.set_line_dash(&js_sys::Array::new()).ok();
}

fn draw_artboard_accent(
    ctx: &CanvasRenderingContext2d,
    doc: &Document,
    panel_selected: &[String],
) {
    if panel_selected.is_empty() {
        return;
    }
    ctx.set_stroke_style_str(ARTBOARD_ACCENT_COLOR);
    ctx.set_line_width(2.0);
    for ab in &doc.artboards {
        if panel_selected.iter().any(|id| id == &ab.id) {
            // 2px outside the 1px default: expand the rect by ~1.5
            // so the outer edge of the accent sits one pixel outside
            // the default border's outer edge.
            let pad = 1.5;
            ctx.stroke_rect(
                ab.x - pad,
                ab.y - pad,
                ab.width + 2.0 * pad,
                ab.height + 2.0 * pad,
            );
        }
    }
}

fn draw_artboard_labels(ctx: &CanvasRenderingContext2d, doc: &Document) {
    // Font set once; zoom-independent sizing deferred (see module-
    // level comment). At the current transform, 11px is the closest
    // equivalent to the theme's panel-row text.
    ctx.set_font("11px sans-serif");
    ctx.set_fill_style_str(ARTBOARD_LABEL_COLOR);
    ctx.set_text_baseline("bottom");
    ctx.set_text_align("left");
    for (i, ab) in doc.artboards.iter().enumerate() {
        let label = format!("{}  {}", i + 1, ab.name);
        // Label sits just above the top-left corner, offset a few
        // document units up.
        let _ = ctx.fill_text(&label, ab.x, ab.y - 3.0);
    }
}

fn draw_artboard_center_mark(ctx: &CanvasRenderingContext2d, ab: &Artboard) {
    let cx = ab.x + ab.width / 2.0;
    let cy = ab.y + ab.height / 2.0;
    let arm = 5.0;
    ctx.set_stroke_style_str(ARTBOARD_MARK_COLOR);
    ctx.set_line_width(1.0);
    ctx.begin_path();
    ctx.move_to(cx - arm, cy);
    ctx.line_to(cx + arm, cy);
    ctx.move_to(cx, cy - arm);
    ctx.line_to(cx, cy + arm);
    ctx.stroke();
}

fn draw_artboard_cross_hairs(ctx: &CanvasRenderingContext2d, ab: &Artboard) {
    let cx = ab.x + ab.width / 2.0;
    let cy = ab.y + ab.height / 2.0;
    ctx.set_stroke_style_str(ARTBOARD_MARK_COLOR);
    ctx.set_line_width(1.0);
    ctx.begin_path();
    ctx.move_to(ab.x, cy);
    ctx.line_to(ab.x + ab.width, cy);
    ctx.move_to(cx, ab.y);
    ctx.line_to(cx, ab.y + ab.height);
    ctx.stroke();
}

fn draw_artboard_safe_areas(ctx: &CanvasRenderingContext2d, ab: &Artboard) {
    // Action-safe at 90%, title-safe at 80%, centered.
    ctx.set_stroke_style_str(ARTBOARD_MARK_COLOR);
    ctx.set_line_width(1.0);
    for frac in [0.9_f64, 0.8_f64].iter() {
        let w = ab.width * frac;
        let h = ab.height * frac;
        let x = ab.x + (ab.width - w) / 2.0;
        let y = ab.y + (ab.height - h) / 2.0;
        ctx.stroke_rect(x, y, w, h);
    }
}

fn draw_artboard_display_marks(ctx: &CanvasRenderingContext2d, doc: &Document) {
    for ab in &doc.artboards {
        if ab.show_center_mark {
            draw_artboard_center_mark(ctx, ab);
        }
        if ab.show_cross_hairs {
            draw_artboard_cross_hairs(ctx, ab);
        }
        if ab.show_video_safe_areas {
            draw_artboard_safe_areas(ctx, ab);
        }
    }
}

// ---------------------------------------------------------------------------
// Public render function
// ---------------------------------------------------------------------------

/// Render the entire document to the canvas.
///
/// `precision` is the Boolean-panel Precision value used when
/// evaluating compound shapes. `panel_selected_artboards` is the
/// ordered list of artboard ids currently panel-selected (used for
/// the accent border at Z-layer 6); pass `&[]` when the Artboards
/// panel isn't wired (e.g., Rust Phase C not yet landed). `generation`
/// is the Model's modification generation, used to epoch the Phase-4c
/// reference-geometry recompute cache (cleared whenever it changes).
pub fn render(
    ctx: &CanvasRenderingContext2d,
    width: f64,
    height: f64,
    doc: &Document,
    precision: f64,
    panel_selected_artboards: &[String],
    mask_isolation_path: Option<&[usize]>,
    layers_isolation_path: Option<&[usize]>,
    brush_libraries: &serde_json::Value,
    id_index: &IdIndex,
    generation: u64,
) {
    // Install the brush registry for this render. Dropped on exit
    // (guard restores the prior value), so nested renders nest safely.
    let _brush_guard = register_brush_libraries(brush_libraries.clone());
    // Install the Model's already-built persistent id->element index so live
    // references resolve and display (REFERENCE_GRAPH.md §2.4 Phase 4b). The
    // clone is O(1) (rpds structure sharing); paint never rebuilds it. The
    // gate in the Model guarantees this equals rebuild_id_index(doc).
    let _ref_index_guard = install_ref_index(id_index.clone());
    // Phase 4c: generation-epoch the reference-geometry recompute cache. The
    // model generation is bumped on every mutation / undo / redo, so this
    // drops the cache on any edit while preserving it across no-edit repaints
    // (pan / zoom / hover, plus this render's fill + selection-trace passes).
    // RUST-ONLY perf cache; no behavior change (gated by a per-hit debug-assert
    // that cached == fresh in `live.rs`).
    crate::geometry::live::set_recompute_cache_generation(generation);

    // Layer 1 (canvas background) is now painted by the caller
    // (workspace::app_state::repaint) BEFORE applying the
    // view transform, so the background fills the viewport in
    // screen-space rather than the document rectangle. The
    // (width, height) parameters here are now informational only —
    // the renderer assumes the caller has cleared / filled the
    // viewport and applied the zoom + pan transform.
    let _ = (width, height);

    // Layer 2: artboard fills (list order, later wins in overlaps).
    draw_artboard_fills(ctx, doc);

    // Layer 3: document element tree. In mask-isolation mode
    // (OPACITY.md §Preview interactions), render only the mask
    // subtree of the isolated element — everything else on the
    // canvas is hidden until the user exits isolation.
    if let Some(path) = mask_isolation_path {
        if let Some(elem) = doc.get_element(&path.to_vec()) {
            if let Some(mask) = elem.common().mask.as_deref() {
                draw_element(ctx, &mask.subtree, Visibility::Preview, precision);
            }
        }
    } else if let Some(iso_path) = layers_isolation_path {
        // Layers-panel isolation visual (LYR-181):
        //   - Non-isolated elements render at low alpha (parent_alpha
        //     multiplies through draw_element_body).
        //   - Isolated subtree paints over them at full alpha.
        // Artboard fills (already painted above) stay full strength.
        // The dim pass is guarded in its own block: the isolated subtree
        // below must paint at FULL alpha, so the span ends exactly where the
        // manual restore() stood (see CtxSaveGuard).
        {
            let _ctx_guard = CtxSaveGuard::new(ctx);
            ctx.set_global_alpha(0.15);
            for layer in &doc.layers {
                draw_element(ctx, layer, Visibility::Preview, precision);
            }
        }
        if let Some(iso_elem) = doc.get_element(&iso_path.to_vec()) {
            draw_element(ctx, iso_elem, Visibility::Preview, precision);
        }
    } else {
        for layer in &doc.layers {
            draw_element(ctx, layer, Visibility::Preview, precision);
        }
    }

    // Layer 4: fade overlay (dims regions outside any artboard).
    draw_fade_overlay(ctx, doc, width, height);

    // Layer 5: artboard borders (thin, above elements so they're
    // never occluded).
    draw_artboard_borders(ctx, doc);

    // Layer 5b: bleed guide rectangles (PRINT.md §1A) — drawn just
    // outside artboards when document_setup.bleed_* is non-zero.
    draw_bleed_guides(ctx, doc);

    // Layer 6: accent borders for panel-selected artboards.
    draw_artboard_accent(ctx, doc, panel_selected_artboards);

    // Layer 7: artboard labels above top-left.
    draw_artboard_labels(ctx, doc);

    // Layer 8: per-artboard display marks.
    draw_artboard_display_marks(ctx, doc);

    // Layer 9: selection overlays — unchanged.
    draw_selection_overlays(ctx, doc);
}

#[cfg(test)]
mod tests {
    use super::*;

    // The CtxSaveGuard contract tests moved with the guard itself —
    // see canvas/ctx_guard.rs.

    #[test]
    fn render_resolver_resolves_concepts_from_registry() {
        // The production render resolver resolves concept packs from the bundled
        // workspace registry, so a Generated instance evaluates to its concept's
        // geometry on the canvas render path (CONCEPTS.md 3b).
        use crate::geometry::live::ElementResolver;
        let def = RenderResolver
            .resolve_concept("regular_polygon")
            .expect("regular_polygon registered in the workspace");
        assert!(def.generator.contains("cos("));
        assert!(RenderResolver.resolve_concept("no_such_concept").is_none());

        let ge = crate::geometry::live::GeneratedElem::new(
            "regular_polygon".into(),
            serde_json::json!({ "sides": 4, "radius": 10 }),
            crate::geometry::element::CommonProps::default(),
        );
        let mut visiting = crate::geometry::live::VisitSet::new();
        let ps = ge.evaluate_with(1.0, &RenderResolver, &mut visiting);
        assert_eq!(ps.len(), 1, "one ring");
        assert_eq!(ps[0].len(), 4, "a square has 4 vertices");
    }

    #[test]
    fn css_color_opaque_black() {
        let c = Color::Rgb { r: 0.0, g: 0.0, b: 0.0, a: 1.0 };
        assert_eq!(css_color(&c), "rgb(0,0,0)");
    }

    // An element's own STROKE is drawn UNDER the element transform, so the
    // matrix would scale the stroke width (on top of any scale_strokes bake) —
    // a double-scale. `transform_scale_factor` is the per-transform
    // sqrt(|det|); `counter_scaled_element` accumulates it down the ancestor
    // chain and returns a COPY of the element whose stroke width is divided by
    // that scale, so EVERY stroke.width reader (the pen width AND the Line
    // arrowhead setback) sees the divided width — matching the Python/OCaml
    // element-copy reference (8ac2f4d1 / 60ed68fb). The element transform never
    // thickens the stroke (it stays zoom-scaled).
    #[test]
    fn transform_scale_factor_cases() {
        // None -> identity scale.
        assert_eq!(transform_scale_factor(None), 1.0);
        // Uniform 2x -> sqrt(2*2) = 2.
        let t2 = Transform { a: 2.0, b: 0.0, c: 0.0, d: 2.0, e: 0.0, f: 0.0 };
        assert_eq!(transform_scale_factor(Some(&t2)), 2.0);
        // det = 2 * 8 = 16 -> sqrt = 4.
        let t16 = Transform { a: 2.0, b: 0.0, c: 0.0, d: 8.0, e: 0.0, f: 0.0 };
        assert_eq!(transform_scale_factor(Some(&t16)), 4.0);
        // Degenerate (det 0) -> 1.0, never a divide-by-zero.
        let t0 = Transform { a: 0.0, b: 0.0, c: 0.0, d: 0.0, e: 0.0, f: 0.0 };
        assert_eq!(transform_scale_factor(Some(&t0)), 1.0);
    }

    // Build a stroked rect (stroke width `w`) carrying the given own transform.
    fn stroked_rect(w: f64, transform: Option<Transform>) -> Element {
        use crate::geometry::element::{RectElem, CommonProps};
        let mut common = CommonProps::default();
        common.transform = transform;
        Element::Rect(RectElem {
            x: 0.0, y: 0.0, width: 10.0, height: 10.0, rx: 0.0, ry: 0.0,
            fill: None,
            stroke: Some(Stroke::new(Color::new(0.0, 0.0, 0.0, 1.0), w)),
            common,
            fill_gradient: None, stroke_gradient: None,
        })
    }

    // -----------------------------------------------------------------
    // PH4 — the counter-scale divergence guard
    // -----------------------------------------------------------------

    fn scale2() -> Transform { Transform { a: 2.0, b: 0.0, c: 0.0, d: 2.0, e: 0.0, f: 0.0 } }

    fn filled_rect(transform: Option<Transform>) -> Element {
        use crate::geometry::element::{CommonProps, Fill, RectElem};
        let mut common = CommonProps::default();
        common.transform = transform;
        Element::Rect(RectElem {
            x: 0.0, y: 0.0, width: 10.0, height: 10.0, rx: 0.0, ry: 0.0,
            fill: Some(Fill { color: Color::new(0.0, 0.0, 0.0, 1.0), opacity: 1.0 }),
            stroke: None, common, fill_gradient: None, stroke_gradient: None,
        })
    }

    fn group_of(children: Vec<Element>, transform: Option<Transform>) -> Element {
        use crate::geometry::element::{CommonProps, GroupElem};
        use std::rc::Rc;
        let mut common = CommonProps::default();
        common.transform = transform;
        Element::Group(GroupElem {
            children: children.into_iter().map(Rc::new).collect(),
            common, isolated_blending: false, knockout_group: false,
        })
    }

    fn with_mask(mut elem: Element, artwork: Element) -> Element {
        use crate::geometry::element::Mask;
        elem.common_mut().mask = Some(Box::new(Mask {
            subtree: Box::new(artwork),
            clip: true, invert: false, disabled: false,
            linked: true, unlink_transform: None,
        }));
        elem
    }

    /// The guard fires exactly where `counter_scaled_element` would DO
    /// something — a stroke (or a rounded corner) under a non-unit accumulated
    /// element scale — and nowhere else.
    #[test]
    fn counter_scale_guard_fires_on_a_scaled_stroke_only() {
        // A stroke at unit scale: nothing to counter-scale.
        assert!(!subtree_would_be_counter_scaled(&stroked_rect(4.0, None), 1.0));
        // The same stroke under a 2x transform: production would halve the width.
        assert!(subtree_would_be_counter_scaled(&stroked_rect(4.0, Some(scale2())), 1.0));
        // …and the scale can arrive from the ANCESTOR chain instead.
        assert!(subtree_would_be_counter_scaled(&stroked_rect(4.0, None), 2.0));
        // A FILL under the same 2x transform is untouched by counter-scaling.
        assert!(!subtree_would_be_counter_scaled(&filled_rect(Some(scale2())), 1.0),
                "counter-scaling only rewrites stroke width and corner radii; \
                 refusing a plain fill would convert nothing under any zoom");
    }

    /// A rounded rect's radii are counter-scaled too, so it is the second
    /// carrier — and it has its own arm because a guard reading only `stroke()`
    /// passes every assertion above.
    #[test]
    fn counter_scale_guard_fires_on_a_scaled_rounded_rect() {
        let mut r = filled_rect(Some(scale2()));
        if let Element::Rect(e) = &mut r { e.rx = 3.0; e.ry = 3.0; }
        assert!(subtree_would_be_counter_scaled(&r, 1.0));
        // CONTROL: the same corner at unit scale converts.
        let mut r = filled_rect(None);
        if let Element::Rect(e) = &mut r { e.rx = 3.0; e.ry = 3.0; }
        assert!(!subtree_would_be_counter_scaled(&r, 1.0));
    }

    /// It reaches DESCENDANTS, accumulating the scale on the way down — which
    /// is the arm that matters, because the A6 bracket swallows a subtree.
    #[test]
    fn counter_scale_guard_accumulates_down_the_children() {
        // The scale is on the GROUP; the stroke is on the child.
        let g = group_of(vec![stroked_rect(4.0, None)], Some(scale2()));
        assert!(subtree_would_be_counter_scaled(&g, 1.0));
        // CONTROL: the same tree with no transform anywhere converts.
        let g = group_of(vec![stroked_rect(4.0, None)], None);
        assert!(!subtree_would_be_counter_scaled(&g, 1.0));
    }

    /// ⛔ AND THE MASK ARTWORK RESTARTS AT THE IDENTITY, because
    /// `draw_element_with_mask` renders the subtree through `draw_element`,
    /// whose public entry seeds the element scale at 1.0. A guard that threaded
    /// the element's scale into the artwork would refuse documents production
    /// renders identically — the wrong direction for a divergence guard, since
    /// it converts less while claiming to protect more.
    #[test]
    fn counter_scale_guard_restarts_the_accumulation_inside_the_mask() {
        // Element scaled 2x, mask artwork stroked and UNTRANSFORMED: the artwork
        // is drawn at scale 1.0 by legacy, so there is nothing to diverge on…
        let e = with_mask(filled_rect(Some(scale2())), stroked_rect(4.0, None));
        assert!(!subtree_would_be_counter_scaled(&e, 1.0),
                "the mask artwork does not inherit the element's scale");
        // …while artwork carrying its OWN scale does fire.
        let e = with_mask(filled_rect(None), stroked_rect(4.0, Some(scale2())));
        assert!(subtree_would_be_counter_scaled(&e, 1.0));
    }

    /// A DISABLED mask is never drawn, so its artwork cannot diverge.
    #[test]
    fn counter_scale_guard_ignores_a_disabled_masks_artwork() {
        let mut e = with_mask(filled_rect(None), stroked_rect(4.0, Some(scale2())));
        e.common_mut().mask.as_mut().unwrap().disabled = true;
        assert!(!subtree_would_be_counter_scaled(&e, 1.0));
    }

    #[test]
    fn counter_scaled_element_divides_stroke() {
        // A stroked rect (width 4) with its own 2x transform: combined scale is
        // 2.0, so the returned COPY's stroke width is 4 / 2 = 2.0.
        let t2 = Transform { a: 2.0, b: 0.0, c: 0.0, d: 2.0, e: 0.0, f: 0.0 };
        let rect = stroked_rect(4.0, Some(t2));
        let (copy, scale) = counter_scaled_element(&rect, 1.0);
        assert_eq!(scale, 2.0);
        assert_eq!(copy.stroke().unwrap().width, 2.0);
    }

    #[test]
    fn counter_scaled_element_no_transform_unchanged() {
        // No transform -> scale 1.0 -> element returned unchanged (width 4).
        let rect = stroked_rect(4.0, None);
        let (copy, scale) = counter_scaled_element(&rect, 1.0);
        assert_eq!(scale, 1.0);
        assert_eq!(copy.stroke().unwrap().width, 4.0);
    }

    #[test]
    fn counter_scaled_element_accumulates_with_parent() {
        // A stroked rect (width 12) with its own 2x, inside a parent already at
        // 3x: combined scale is 3 * 2 = 6, so the copy's width is 12 / 6 = 2.0.
        let t2 = Transform { a: 2.0, b: 0.0, c: 0.0, d: 2.0, e: 0.0, f: 0.0 };
        let rect = stroked_rect(12.0, Some(t2));
        let (copy, scale) = counter_scaled_element(&rect, 3.0);
        assert_eq!(scale, 6.0);
        assert_eq!(copy.stroke().unwrap().width, 2.0);
    }

    #[test]
    fn counter_scaled_element_divides_corners() {
        use crate::geometry::element::{RectElem, CommonProps};
        // A rounded rect (rx/ry 10) with a 2x transform: corner radii are
        // counter-scaled to 5, so the rendered corner stays fixed.
        let mut common = CommonProps::default();
        common.transform = Some(Transform { a: 2.0, b: 0.0, c: 0.0, d: 2.0, e: 0.0, f: 0.0 });
        let rect = Element::Rect(RectElem {
            x: 0.0, y: 0.0, width: 100.0, height: 100.0, rx: 10.0, ry: 10.0,
            fill: None, stroke: None, common,
            fill_gradient: None, stroke_gradient: None,
        });
        let (copy, scale) = counter_scaled_element(&rect, 1.0);
        assert_eq!(scale, 2.0);
        if let Element::Rect(r) = &copy {
            assert_eq!(r.rx, 5.0);
            assert_eq!(r.ry, 5.0);
        } else {
            panic!("expected rect");
        }
    }

    #[test]
    fn rebuild_id_index_indexes_descendants_and_sorted_masters() {
        // The pure builder (REFERENCE_GRAPH.md §2.3) indexes id-bearing layer
        // descendants and doc.symbols masters; top-level layers are skipped.
        // This is the single canonical walk shared by paint and the gate, so
        // its result must match what RenderResolver reads via the thread-local.
        use crate::geometry::element::{RectElem, CommonProps};
        let mut rect = RectElem {
            x: 0.0, y: 0.0, width: 10.0, height: 10.0, rx: 0.0, ry: 0.0,
            fill: None, stroke: None, common: CommonProps::default(),
            fill_gradient: None, stroke_gradient: None,
        };
        rect.common.id = Some("r1".into());
        let mut doc = Document::default();
        // The default layer carries an id; it must NOT be a resolution target.
        doc.layers[0].common_mut().id = Some("layer0".into());
        doc.layers[0].children_mut().unwrap()
            .push(std::rc::Rc::new(Element::Rect(rect)));
        let master = Element::Rect(RectElem {
            x: 1.0, y: 2.0, width: 3.0, height: 4.0, rx: 0.0, ry: 0.0,
            fill: None, stroke: None,
            common: CommonProps { id: Some("m1".into()), ..Default::default() },
            fill_gradient: None, stroke_gradient: None,
        });
        doc.symbols = vec![master];

        let index = rebuild_id_index(&doc);
        assert!(index.get("r1").is_some(), "descendant rect is indexed by id");
        assert!(index.get("m1").is_some(), "master is indexed from doc.symbols");
        assert!(
            index.get("layer0").is_none(),
            "a top-level layer's own id is not a resolution target",
        );
        // The persistent map equals itself rebuilt (the gate's equality used by
        // the Model) — and a fresh install resolves identically.
        assert!(index == rebuild_id_index(&doc), "rebuild is deterministic");
        let _guard = install_ref_index(index);
        use crate::geometry::live::ElementRef;
        assert!(RenderResolver.resolve(&ElementRef("r1".into())).is_some());
        assert!(RenderResolver.resolve(&ElementRef("m1".into())).is_some());
    }

    // --- Phase 4b incremental maintenance (REFERENCE_GRAPH.md §2.4) ---
    //
    // `incremental_update_index` must produce a map that is value-equal to a
    // from-scratch `rebuild_id_index` of the new document, for any edit. These
    // tests assert that equality directly (the same property the Model's
    // debug-assert gate enforces on every edit), exercising each diff arm:
    // unchanged-subtree skip, old-only remove, new-only add, plus the symbols
    // and structural cases.

    #[cfg(test)]
    fn ix_rect(id: &str) -> std::rc::Rc<Element> {
        use crate::geometry::element::{RectElem, CommonProps};
        std::rc::Rc::new(Element::Rect(RectElem {
            x: 0.0, y: 0.0, width: 10.0, height: 10.0, rx: 0.0, ry: 0.0,
            fill: None, stroke: None,
            common: CommonProps { id: Some(id.into()), ..Default::default() },
            fill_gradient: None, stroke_gradient: None,
        }))
    }

    #[cfg(test)]
    fn ix_group(id: &str, children: Vec<std::rc::Rc<Element>>) -> std::rc::Rc<Element> {
        use crate::geometry::element::{GroupElem, CommonProps};
        std::rc::Rc::new(Element::Group(GroupElem {
            children,
            isolated_blending: false, knockout_group: false,
            common: CommonProps { id: Some(id.into()), ..Default::default() },
        }))
    }

    #[test]
    fn incremental_leaf_value_edit_equals_rebuild() {
        // A deep CoW edit: one shared sibling stays Rc-identical (skipped),
        // the edited node appears as old-only (removed) + new-only (added).
        let mut old = Document::default();
        let shared = ix_rect("shared");
        let before = ix_rect("edited");
        old.layers[0].children_mut().unwrap().push(shared.clone());
        old.layers[0].children_mut().unwrap().push(before);

        let mut new = old.clone();
        // Replace "edited" in place with a NEW Rc (different pointer); "shared"
        // keeps its original Rc pointer (structure sharing).
        new.layers[0].children_mut().unwrap()[1] = ix_rect("edited_v2");

        let idx = rebuild_id_index(&old);
        let updated = incremental_update_index(idx, &old, &new);
        assert_eq!(updated, rebuild_id_index(&new), "leaf edit matches rebuild");
        assert!(updated.get("edited").is_none(), "old id removed");
        assert!(updated.get("edited_v2").is_some(), "new id added");
        assert!(updated.get("shared").is_some(), "unchanged sibling retained");
    }

    #[test]
    fn incremental_subtree_replace_equals_rebuild() {
        // Replace a whole group subtree (with descendants) by a new group.
        let mut old = Document::default();
        old.layers[0].children_mut().unwrap()
            .push(ix_group("g", vec![ix_rect("a"), ix_rect("b")]));
        let mut new = old.clone();
        new.layers[0].children_mut().unwrap()[0] =
            ix_group("g2", vec![ix_rect("c"), ix_rect("d")]);

        let idx = rebuild_id_index(&old);
        let updated = incremental_update_index(idx, &old, &new);
        assert_eq!(updated, rebuild_id_index(&new), "subtree replace matches rebuild");
        for gone in ["g", "a", "b"] {
            assert!(updated.get(gone).is_none(), "{gone} removed with old subtree");
        }
        for added in ["g2", "c", "d"] {
            assert!(updated.get(added).is_some(), "{added} added with new subtree");
        }
    }

    #[test]
    fn incremental_insert_equals_rebuild() {
        let mut old = Document::default();
        old.layers[0].children_mut().unwrap().push(ix_rect("a"));
        let mut new = old.clone();
        new.layers[0].children_mut().unwrap().push(ix_rect("b"));

        let idx = rebuild_id_index(&old);
        let updated = incremental_update_index(idx, &old, &new);
        assert_eq!(updated, rebuild_id_index(&new), "insert matches rebuild");
        assert!(updated.get("a").is_some());
        assert!(updated.get("b").is_some());
    }

    #[test]
    fn incremental_delete_equals_rebuild() {
        let mut old = Document::default();
        old.layers[0].children_mut().unwrap().push(ix_rect("a"));
        old.layers[0].children_mut().unwrap().push(ix_rect("b"));
        let mut new = old.clone();
        new.layers[0].children_mut().unwrap().remove(0); // delete "a"

        let idx = rebuild_id_index(&old);
        let updated = incremental_update_index(idx, &old, &new);
        assert_eq!(updated, rebuild_id_index(&new), "delete matches rebuild");
        assert!(updated.get("a").is_none(), "deleted id removed");
        assert!(updated.get("b").is_some(), "survivor retained");
    }

    #[test]
    fn incremental_symbols_add_and_remove_equals_rebuild() {
        use crate::geometry::element::{RectElem, CommonProps};
        let master = |id: &str| Element::Rect(RectElem {
            x: 0.0, y: 0.0, width: 1.0, height: 1.0, rx: 0.0, ry: 0.0,
            fill: None, stroke: None,
            common: CommonProps { id: Some(id.into()), ..Default::default() },
            fill_gradient: None, stroke_gradient: None,
        });
        let mut old = Document::default();
        old.symbols = vec![master("m1")];
        // Add a master and remove the existing one.
        let mut new = old.clone();
        new.symbols = vec![master("m2")];

        let idx = rebuild_id_index(&old);
        let updated = incremental_update_index(idx, &old, &new);
        assert_eq!(updated, rebuild_id_index(&new), "symbols edit matches rebuild");
        assert!(updated.get("m1").is_none(), "removed master gone");
        assert!(updated.get("m2").is_some(), "added master indexed");
    }

    #[test]
    fn incremental_no_change_is_identity_against_rebuild() {
        let mut old = Document::default();
        old.layers[0].children_mut().unwrap().push(ix_rect("a"));
        let new = old.clone(); // every Rc pointer-identical
        let idx = rebuild_id_index(&old);
        let updated = incremental_update_index(idx, &old, &new);
        assert_eq!(updated, rebuild_id_index(&new), "no-op matches rebuild");
    }

    #[test]
    fn render_ref_index_resolves_reference_to_target() {
        // register_ref_index builds the per-paint id->element index from the
        // document; RenderResolver reads it, so a reference resolves and
        // evaluates to its target's geometry (Phase 1b render wiring).
        use crate::geometry::element::{RectElem, CommonProps};
        use crate::geometry::live::{ReferenceElem, ElementRef, VisitSet, DEFAULT_PRECISION};
        let mut rect = RectElem {
            x: 0.0, y: 0.0, width: 10.0, height: 10.0, rx: 0.0, ry: 0.0,
            fill: None, stroke: None, common: CommonProps::default(),
            fill_gradient: None, stroke_gradient: None,
        };
        rect.common.id = Some("r1".into());
        let mut doc = Document::default();
        doc.layers[0].children_mut().unwrap()
            .push(std::rc::Rc::new(Element::Rect(rect)));
        let _guard = register_ref_index(&doc);
        assert!(
            RenderResolver.resolve(&ElementRef("r1".into())).is_some(),
            "register_ref_index should index the rect by its id",
        );
        let reference = ReferenceElem::new(ElementRef("r1".into()), CommonProps::default());
        let mut visiting = VisitSet::new();
        let ps = reference.evaluate_with(DEFAULT_PRECISION, &RenderResolver, &mut visiting);
        assert_eq!(ps.len(), 1, "reference resolves to the rect's single ring");
        assert!(
            RenderResolver.resolve(&ElementRef("missing".into())).is_none(),
            "an unindexed id resolves to None (dangling)",
        );
    }

    #[test]
    fn render_ref_index_resolves_master_from_symbols() {
        // SYMBOLS.md §10: register_ref_index ALSO indexes doc.symbols, so an
        // instance resolves a master whose ONLY home is the off-canvas store.
        // The master is NOT in layers, so render never paints it — verified by
        // asserting the layer is empty while the master still resolves.
        use crate::geometry::element::{RectElem, CommonProps};
        use crate::geometry::live::{ReferenceElem, ElementRef, VisitSet, DEFAULT_PRECISION};
        let master = Element::Rect(RectElem {
            x: 9.0, y: 18.0, width: 27.0, height: 36.0, rx: 0.0, ry: 0.0,
            fill: None, stroke: None,
            common: CommonProps { id: Some("m1".into()), ..Default::default() },
            fill_gradient: None, stroke_gradient: None,
        });
        let mut doc = Document::default();
        doc.symbols = vec![master];
        // The instance lives in a layer; the master does NOT.
        doc.layers[0].children_mut().unwrap().push(std::rc::Rc::new(Element::Live(
            crate::geometry::live::LiveVariant::Reference(ReferenceElem::new(
                ElementRef("m1".into()),
                CommonProps { id: Some("i1".into()), ..Default::default() },
            )),
        )));

        let _guard = register_ref_index(&doc);
        // The master (off-canvas) resolves by its own id from doc.symbols.
        assert!(
            RenderResolver.resolve(&ElementRef("m1".into())).is_some(),
            "register_ref_index must index masters from doc.symbols",
        );
        // The instance evaluates to the master's geometry (a single ring).
        let instance = ReferenceElem::new(ElementRef("m1".into()), CommonProps::default());
        let mut visiting = VisitSet::new();
        let ps = instance.evaluate_with(DEFAULT_PRECISION, &RenderResolver, &mut visiting);
        assert_eq!(ps.len(), 1, "instance resolves to the master rect's single ring");

        // Masters are never painted: the master appears only in doc.symbols,
        // never in the layer tree (the off-canvas guarantee).
        let only_child = doc.layers[0].children().unwrap();
        assert_eq!(only_child.len(), 1, "layer holds only the instance");
        assert!(
            matches!(&*only_child[0], Element::Live(_)),
            "the layer's sole child is the instance (a reference), not the master",
        );
        assert_eq!(doc.symbols.len(), 1, "the master lives only in doc.symbols");
    }

    // ── bleed rect (PRINT.md §1A) ──────────────────────────

    fn ab_at(x: f64, y: f64, w: f64, h: f64) -> crate::document::artboard::Artboard {
        crate::document::artboard::Artboard {
            x, y, width: w, height: h,
            ..crate::document::artboard::Artboard::default_with_id("ab".to_string())
        }
    }

    #[test]
    fn bleed_rect_none_when_all_zero() {
        let ab = ab_at(10.0, 20.0, 100.0, 200.0);
        let s = crate::document::document_setup::DocumentSetup::default();
        assert_eq!(bleed_rect_for_artboard(&ab, &s), None);
    }

    #[test]
    fn bleed_rect_uniform_extends_all_sides() {
        let ab = ab_at(10.0, 20.0, 100.0, 200.0);
        let mut s = crate::document::document_setup::DocumentSetup::default();
        s.bleed_top = 5.0;
        s.bleed_right = 5.0;
        s.bleed_bottom = 5.0;
        s.bleed_left = 5.0;
        assert_eq!(bleed_rect_for_artboard(&ab, &s), Some((5.0, 15.0, 110.0, 210.0)));
    }

    #[test]
    fn bleed_rect_partial_only_offsets_sides_with_bleed() {
        let ab = ab_at(10.0, 20.0, 100.0, 200.0);
        let mut s = crate::document::document_setup::DocumentSetup::default();
        s.bleed_left = 7.0; // top/right/bottom remain 0
        assert_eq!(bleed_rect_for_artboard(&ab, &s), Some((3.0, 20.0, 107.0, 200.0)));
    }

    #[test]
    fn css_color_opaque_white() {
        let c = Color::Rgb { r: 1.0, g: 1.0, b: 1.0, a: 1.0 };
        assert_eq!(css_color(&c), "rgb(255,255,255)");
    }

    #[test]
    fn css_color_opaque_red() {
        let c = Color::Rgb { r: 1.0, g: 0.0, b: 0.0, a: 1.0 };
        assert_eq!(css_color(&c), "rgb(255,0,0)");
    }

    #[test]
    fn css_color_transparent() {
        let c = Color::Rgb { r: 1.0, g: 0.0, b: 0.0, a: 0.5 };
        assert_eq!(css_color(&c), "rgba(255,0,0,0.5)");
    }

    #[test]
    fn css_color_fully_transparent() {
        let c = Color::Rgb { r: 0.0, g: 0.0, b: 0.0, a: 0.0 };
        assert_eq!(css_color(&c), "rgba(0,0,0,0)");
    }

    #[test]
    fn css_color_mid_gray() {
        let c = Color::Rgb { r: 0.5, g: 0.5, b: 0.5, a: 1.0 };
        assert_eq!(css_color(&c), "rgb(127,127,127)");
    }

    // ── blend_mode_css ─────────────────────────────────────

    #[test]
    fn blend_mode_css_normal_is_source_over() {
        assert_eq!(blend_mode_css(BlendMode::Normal), "source-over");
    }

    #[test]
    fn blend_mode_css_maps_all_sixteen_variants() {
        // Every variant must map to a non-empty Canvas2D composite
        // operation name. Underscore variants in the Rust enum must
        // become hyphenated in CSS (color_burn → "color-burn").
        let pairs = [
            (BlendMode::Normal,      "source-over"),
            (BlendMode::Darken,      "darken"),
            (BlendMode::Multiply,    "multiply"),
            (BlendMode::ColorBurn,   "color-burn"),
            (BlendMode::Lighten,     "lighten"),
            (BlendMode::Screen,      "screen"),
            (BlendMode::ColorDodge,  "color-dodge"),
            (BlendMode::Overlay,     "overlay"),
            (BlendMode::SoftLight,   "soft-light"),
            (BlendMode::HardLight,   "hard-light"),
            (BlendMode::Difference,  "difference"),
            (BlendMode::Exclusion,   "exclusion"),
            (BlendMode::Hue,         "hue"),
            (BlendMode::Saturation,  "saturation"),
            (BlendMode::Color,       "color"),
            (BlendMode::Luminosity,  "luminosity"),
        ];
        assert_eq!(pairs.len(), 16);
        for (mode, expected) in pairs {
            assert_eq!(blend_mode_css(mode), expected,
                       "mapping mismatch for {:?}", mode);
        }
    }

    #[test]
    fn blend_mode_css_hyphenates_compound_names() {
        assert_eq!(blend_mode_css(BlendMode::ColorBurn), "color-burn");
        assert_eq!(blend_mode_css(BlendMode::ColorDodge), "color-dodge");
        assert_eq!(blend_mode_css(BlendMode::SoftLight), "soft-light");
        assert_eq!(blend_mode_css(BlendMode::HardLight), "hard-light");
    }

    // ── mask_plan (Track C) ────────────────────────────────

    fn test_mask(clip: bool, invert: bool, disabled: bool) -> Mask {
        Mask {
            subtree: Box::new(Element::Group(GroupElem::default())),
            clip,
            invert,
            disabled,
            linked: true,
            unlink_transform: None,
        }
    }

    #[test]
    fn mask_blit_alpha_carries_the_inherited_ancestor_product() {
        // D-alpha, half 1: set_global_alpha REPLACES, so the blit must carry
        // the ancestors or their alpha is silently dropped.
        assert_eq!(mask_blit_alpha(0.5, 1.0), 0.5);
        assert_eq!(mask_blit_alpha(0.25, 0.8), 0.25);
    }

    #[test]
    fn mask_blit_alpha_is_independent_of_own_opacity() {
        // D-alpha, half 2: the scratch already carries own_opacity. Re-applying
        // it here squares it. This is the assertion that fails if anyone
        // reinstates `elem.opacity()` -- or "fixes" it to parent * opacity.
        for own in [0.0, 0.25, 0.5, 1.0] {
            assert_eq!(
                mask_blit_alpha(0.5, own), 0.5,
                "blit alpha must not vary with own_opacity (got own={own})"
            );
        }
    }

    #[test]
    fn masked_effective_alpha_is_the_product_each_factor_once() {
        // The net the artist sees: scratch (own) x blit (ancestors).
        // Discriminating cases -- 0.5/0.5 is NOT one, because the squared
        // defect and the correct law both yield 0.25 there.
        let net = |parent: f64, own: f64| own * mask_blit_alpha(parent, own);
        assert_eq!(net(1.0, 0.5), 0.5);  // squared defect would give 0.25
        assert_eq!(net(0.5, 1.0), 0.5);  // ancestor-ignored would give 1.0
        assert_eq!(net(0.5, 0.5), 0.25); // the design block's example
    }

    /// ⛔ THIS TEST HAD NO `#[test]` ATTRIBUTE AND HAD NEVER RUN. Its three
    /// neighbours carry one; this one was written, committed, and silently
    /// excluded — so the case it covers, `(clip: true, invert: false)`, THE
    /// STANDARD OPACITY MASK, had no coverage at all. rustc said so the whole
    /// time ("function is never used"), inside 52 warnings.
    /// Found 2026-08-27 by mutating the lowering and watching NOTHING go red.
    #[test]
    fn mask_plan_clip_not_inverted_is_clip_in() {
        let m = test_mask(true, false, false);
        assert_eq!(mask_plan(&m), Some(MaskPlan::ClipIn));
    }

    

    // ── D-β: THE FAILING INPUT, WRITTEN FIRST ─────────────────────────────
    //
    // Design block §2.2: a masked element whose body contains another masked
    // element re-enters `draw_element_with_mask`, which hands the SAME static
    // scratch to the inner call, whose `clear_rect` wipes the outer call's
    // half-drawn buffer. Mask-in-mask and masked-child-of-masked-group were
    // silently wrong.
    //
    // ⛔ THE TWO ARMS MUST DIFFER, and this is exactly where they do: the OLD
    // behaviour is "every acquisition is buffer 0"; the repair is "a nested
    // acquisition gets a distinct index". A test that only asserted the repair
    // would pass against the singleton too if the singleton returned 0 once.

    /// The defect, modelled as the singleton behaved: every caller, at any
    /// depth, receives the same buffer. Kept as the RED arm so the difference
    /// is visible in the suite rather than asserted in a commit message.
    fn singleton_acquire(_depth: usize) -> usize {
        0
    }

    #[test]
    fn d_beta_singleton_hands_the_same_buffer_to_a_nested_call() {
        // outer acquires, then the inner (nested) call acquires
        let outer = singleton_acquire(0);
        let inner = singleton_acquire(1);
        assert_eq!(
            outer, inner,
            "this arm PINS THE DEFECT: the singleton gave both calls buffer {outer}, \
             so the inner clear_rect wiped the outer's content"
        );
    }

    #[test]
    fn d_beta_stack_gives_a_nested_call_its_own_buffer() {
        let mut s = ScratchDepth::default();
        let outer = s.acquire();
        let inner = s.acquire();
        assert_ne!(
            outer, inner,
            "a nested acquisition MUST NOT alias the outer buffer — that is D-β"
        );
        assert_eq!((outer, inner), (0, 1));
        assert_eq!(s.live(), 2, "both are live while nested");
        s.release();
        assert_eq!(s.live(), 1, "releasing the inner leaves the outer live");
        s.release();
        assert_eq!(s.live(), 0);
        // the pool must be sized by the deepest nesting actually seen
        assert_eq!(s.high_water(), 2);
    }

    /// ⛔ AND THE ARMS MUST DIFFER FROM EACH OTHER, asserted rather than assumed:
    /// the singleton and the stack disagree on the nested case, which is the
    /// entire content of the defect. If a future edit made them agree, this
    /// reds even if both arms above still pass in isolation.
    #[test]
    fn d_beta_the_two_arms_disagree_on_the_nested_case() {
        let mut s = ScratchDepth::default();
        let (so, si) = (s.acquire(), s.acquire());
        let (go, gi) = (singleton_acquire(0), singleton_acquire(1));
        assert_eq!(go, gi, "defect arm: aliased");
        assert_ne!(so, si, "repair arm: distinct");
        assert!(
            (go == gi) != (so != si) || true,
            "kept explicit: the two arms describe opposite behaviours"
        );
        assert_ne!((go, gi), (so, si), "the arms must not have collapsed together");
    }

    /// Sequential (non-nested) masked elements REUSE buffer 0 — the repair must
    /// not turn every masked element into a fresh allocation. This is the arm
    /// that stops the fix from being "allocate always", which would pass the
    /// nesting test and regress the frame cost the singleton existed to avoid.
    #[test]
    fn d_beta_sequential_masks_reuse_the_same_buffer() {
        let mut s = ScratchDepth::default();
        let a = s.acquire();
        s.release();
        let b = s.acquire();
        s.release();
        assert_eq!(a, b, "sequential masked elements must reuse the buffer");
        assert_eq!(s.high_water(), 1, "no nesting occurred, so the pool stays at 1");
    }

    #[test]
    fn mask_plan_clip_inverted_is_clip_out() {
        let m = test_mask(true, true, false);
        assert_eq!(mask_plan(&m), Some(MaskPlan::ClipOut));
    }

    #[test]
    fn mask_plan_disabled_is_none() {
        // disabled overrides both clip and invert: falls back to no
        // mask rendering per OPACITY.md §States.
        assert_eq!(mask_plan(&test_mask(true, false, true)), None);
        assert_eq!(mask_plan(&test_mask(true, true, true)), None);
        assert_eq!(mask_plan(&test_mask(false, false, true)), None);
        assert_eq!(mask_plan(&test_mask(false, true, true)), None);
    }

    #[test]
    fn mask_plan_no_clip_no_invert_is_reveal_outside_bbox() {
        // Phase 2: clip=false, invert=false keeps the element
        // visible outside the mask subtree's bounding box and
        // clips to the mask inside it.
        assert_eq!(
            mask_plan(&test_mask(false, false, false)),
            Some(MaskPlan::RevealOutsideBbox)
        );
    }

    #[test]
    fn mask_plan_no_clip_inverted_collapses_to_clip_out() {
        // Alpha-based mask: `clip: false, invert: true` gives the
        // same output as `clip: true, invert: true` because the
        // mask's outside-region alpha is zero either way. Phase 2
        // routes them through the same `ClipOut` path.
        assert_eq!(
            mask_plan(&test_mask(false, true, false)),
            Some(MaskPlan::ClipOut)
        );
    }

    // ── promote_bytes_to_luminance (PDF §11 soft-mask) ─────

    fn pixel(r: u8, g: u8, b: u8, a: u8) -> [u8; 4] { [r, g, b, a] }

    #[test]
    fn luminance_white_opaque_keeps_alpha() {
        let mut bytes = pixel(255, 255, 255, 255).to_vec();
        promote_bytes_to_luminance(&mut bytes);
        assert_eq!(bytes[3], 255);
    }

    #[test]
    fn luminance_black_opaque_drops_to_zero() {
        let mut bytes = pixel(0, 0, 0, 255).to_vec();
        promote_bytes_to_luminance(&mut bytes);
        assert_eq!(bytes[3], 0);
    }

    #[test]
    fn luminance_mid_gray_halves_alpha() {
        // Mid-gray (128,128,128) has luminance ≈ 128. Alpha 255 in,
        // expect ~128 out.
        let mut bytes = pixel(128, 128, 128, 255).to_vec();
        promote_bytes_to_luminance(&mut bytes);
        // Allow ±1 for rounding.
        assert!((bytes[3] as i32 - 128).abs() <= 1, "got {}", bytes[3]);
    }

    #[test]
    fn luminance_transparent_stays_transparent() {
        // Regardless of RGB, an alpha-0 pixel must stay alpha-0
        // (so the mask's "outside rendered region" doesn't
        // accidentally become opaque).
        let mut bytes = pixel(255, 255, 255, 0).to_vec();
        promote_bytes_to_luminance(&mut bytes);
        assert_eq!(bytes[3], 0);
    }

    #[test]
    fn luminance_respects_source_alpha() {
        // Half-alpha white should end up at half alpha.
        let mut bytes = pixel(255, 255, 255, 128).to_vec();
        promote_bytes_to_luminance(&mut bytes);
        assert_eq!(bytes[3], 128);
    }

    #[test]
    fn luminance_bt601_red_weight() {
        // Pure red (255,0,0) → luminance = 0.299 * 255 ≈ 76.
        let mut bytes = pixel(255, 0, 0, 255).to_vec();
        promote_bytes_to_luminance(&mut bytes);
        assert!((bytes[3] as i32 - 76).abs() <= 1, "got {}", bytes[3]);
    }

    #[test]
    fn luminance_bt601_green_weight() {
        // Pure green → luminance = 0.587 * 255 ≈ 150.
        let mut bytes = pixel(0, 255, 0, 255).to_vec();
        promote_bytes_to_luminance(&mut bytes);
        assert!((bytes[3] as i32 - 150).abs() <= 1, "got {}", bytes[3]);
    }

    #[test]
    fn luminance_bt601_blue_weight() {
        // Pure blue → luminance = 0.114 * 255 ≈ 29.
        let mut bytes = pixel(0, 0, 255, 255).to_vec();
        promote_bytes_to_luminance(&mut bytes);
        assert!((bytes[3] as i32 - 29).abs() <= 1, "got {}", bytes[3]);
    }

    // ── effective_mask_transform (Track C phase 3) ────────

    fn test_transform(e: f64, f: f64) -> Transform {
        // Pure translation by (e, f) for easy identification in tests.
        Transform { a: 1.0, b: 0.0, c: 0.0, d: 1.0, e, f }
    }

    fn test_rect_with_transform(t: Option<Transform>) -> Element {
        Element::Rect(RectElem {
            x: 0.0, y: 0.0, width: 10.0, height: 10.0,
            rx: 0.0, ry: 0.0,
            fill: None, stroke: None,
            common: CommonProps {
                opacity: 1.0,
                mode: BlendMode::Normal,
                transform: t,
                locked: false,
                visibility: Visibility::Preview,
                mask: None,
                tool_origin: None,
            name: None,
            id: None,
            },
                    fill_gradient: None,
            stroke_gradient: None,
        })
    }

    fn test_mask_linked(
        linked: bool,
        unlink: Option<Transform>,
    ) -> Mask {
        Mask {
            subtree: Box::new(Element::Group(GroupElem::default())),
            clip: true,
            invert: false,
            disabled: false,
            linked,
            unlink_transform: unlink,
        }
    }

    #[test]
    fn effective_mask_transform_linked_returns_element_transform() {
        // linked=true: mask follows the element, so the renderer
        // should apply ``elem.transform()``.
        let mask = test_mask_linked(true, None);
        let elem = test_rect_with_transform(Some(test_transform(5.0, 7.0)));
        let t = effective_mask_transform(&mask, &elem)
            .expect("expected Some element transform");
        assert_eq!(t.e, 5.0);
        assert_eq!(t.f, 7.0);
    }

    #[test]
    fn effective_mask_transform_linked_none_when_element_has_no_transform() {
        // linked=true with no element transform: None — the
        // compositing path skips the ``ctx.transform`` call.
        let mask = test_mask_linked(true, None);
        let elem = test_rect_with_transform(None);
        assert!(effective_mask_transform(&mask, &elem).is_none());
    }

    #[test]
    fn effective_mask_transform_unlinked_returns_captured_unlink_transform() {
        // linked=false: mask stays frozen under the unlink-time
        // transform, regardless of the element's current transform.
        let unlink = test_transform(3.0, 4.0);
        let mask = test_mask_linked(false, Some(unlink));
        let elem = test_rect_with_transform(Some(test_transform(100.0, 100.0)));
        let t = effective_mask_transform(&mask, &elem)
            .expect("expected Some unlink transform");
        assert_eq!(t.e, 3.0);
        assert_eq!(t.f, 4.0);
    }

    #[test]
    fn effective_mask_transform_unlinked_none_when_unlink_missing() {
        // linked=false with no captured transform (edge case:
        // unlinked at identity): None. Compositing skips the
        // transform call and the mask renders in ancestor coords.
        let mask = test_mask_linked(false, None);
        let elem = test_rect_with_transform(Some(test_transform(7.0, 8.0)));
        assert!(effective_mask_transform(&mask, &elem).is_none());
    }

    #[test]
    fn css_color_alpha_just_below_one() {
        let c = Color::Rgb { r: 0.0, g: 1.0, b: 0.0, a: 0.99 };
        assert_eq!(css_color(&c), "rgba(0,255,0,0.99)");
    }

    // --- Selection control-point handle rects (fixed-size handles) ---
    //
    // The selection control-point handle squares must be FIXED SIZE: an
    // element's transform moves the handle POSITIONS but never scales the
    // handle glyphs. `selection_handle_rects(doc, path)` returns
    // document-space rects whose CENTER is the element-transformed control
    // point and whose SIZE is the constant HANDLE_DRAW_SIZE (NOT multiplied
    // by the element transform). Mirrors the Python reference (commit
    // 08b3f3a9) so all 4 ports stay equivalent.

    #[cfg(test)]
    fn hr_doc_with(elem: Element) -> Document {
        use crate::document::document::ElementSelection;
        let mut doc = Document::default();
        doc.layers[0].children_mut().unwrap()
            .push(std::rc::Rc::new(elem));
        doc.selection = vec![ElementSelection::all(vec![0, 0])];
        doc
    }

    #[cfg(test)]
    fn hr_rect(transform: Option<Transform>) -> Element {
        use crate::geometry::element::{RectElem, CommonProps};
        Element::Rect(RectElem {
            x: 0.0, y: 0.0, width: 100.0, height: 100.0, rx: 0.0, ry: 0.0,
            fill: None, stroke: None,
            common: CommonProps { transform, ..Default::default() },
            fill_gradient: None, stroke_gradient: None,
        })
    }

    /// Sorted (cx, cy) centers of the returned handle rects.
    #[cfg(test)]
    fn hr_centers(rects: &[(f64, f64, f64, f64)]) -> Vec<(f64, f64)> {
        let mut cs: Vec<(f64, f64)> = rects.iter()
            .map(|&(x, y, w, _h)| (x + w / 2.0, y + w / 2.0))
            .collect();
        cs.sort_by(|a, b| a.partial_cmp(b).unwrap());
        cs
    }

    // ── selection_evaluated_bounds (decision-5 Part B.1) ──────────────
    // The Properties panel X/Y/W/H = the selection's EVALUATED bounding box:
    // each element's geometric bbox mapped through its own + ancestor
    // transforms, axis-aligned, unioned. Mirrors the Python
    // selection_evaluated_bounds tests (commit 31e10cf9).

    #[cfg(test)]
    fn eb_rect(x: f64, y: f64, w: f64, h: f64, t: Option<Transform>) -> Element {
        use crate::geometry::element::{RectElem, CommonProps};
        Element::Rect(RectElem {
            x, y, width: w, height: h, rx: 0.0, ry: 0.0,
            fill: None, stroke: None,
            common: CommonProps { transform: t, ..Default::default() },
            fill_gradient: None, stroke_gradient: None,
        })
    }

    #[cfg(test)]
    fn eb_doc(elems: Vec<Element>, selected: Vec<Vec<usize>>) -> Document {
        use crate::document::document::ElementSelection;
        let mut doc = Document::default();
        {
            let children = doc.layers[0].children_mut().unwrap();
            for e in elems {
                children.push(std::rc::Rc::new(e));
            }
        }
        doc.selection = selected.into_iter().map(ElementSelection::all).collect();
        doc
    }

    #[test]
    fn eval_bounds_untransformed_rect() {
        let doc = eb_doc(vec![eb_rect(10.0, 20.0, 30.0, 40.0, None)], vec![vec![0, 0]]);
        assert_eq!(selection_evaluated_bounds(&doc), (10.0, 20.0, 30.0, 40.0));
    }

    #[test]
    fn eval_bounds_scaled_rect_grows() {
        let doc = eb_doc(
            vec![eb_rect(10.0, 20.0, 30.0, 40.0, Some(Transform::scale(2.0, 2.0)))],
            vec![vec![0, 0]]);
        assert_eq!(selection_evaluated_bounds(&doc), (20.0, 40.0, 60.0, 80.0));
    }

    #[test]
    fn eval_bounds_translated_rect_shifts() {
        let doc = eb_doc(
            vec![eb_rect(10.0, 20.0, 30.0, 40.0, Some(Transform::translate(5.0, 7.0)))],
            vec![vec![0, 0]]);
        assert_eq!(selection_evaluated_bounds(&doc), (15.0, 27.0, 30.0, 40.0));
    }

    #[test]
    fn eval_bounds_rotate_90_swaps_extents() {
        // 10x20 rect rotated 90deg -> 20x10 bbox.
        let doc = eb_doc(
            vec![eb_rect(0.0, 0.0, 10.0, 20.0, Some(Transform::rotate(90.0)))],
            vec![vec![0, 0]]);
        let (_x, _y, w, h) = selection_evaluated_bounds(&doc);
        assert!((w - 20.0).abs() < 1e-6, "w={}", w);
        assert!((h - 10.0).abs() < 1e-6, "h={}", h);
    }

    #[test]
    fn eval_bounds_union_of_two() {
        let doc = eb_doc(
            vec![eb_rect(0.0, 0.0, 10.0, 10.0, None),
                 eb_rect(100.0, 0.0, 10.0, 10.0, None)],
            vec![vec![0, 0], vec![0, 1]]);
        assert_eq!(selection_evaluated_bounds(&doc), (0.0, 0.0, 110.0, 10.0));
    }

    #[test]
    fn eval_bounds_empty_selection_is_zero() {
        let doc = eb_doc(vec![eb_rect(10.0, 20.0, 30.0, 40.0, None)], vec![]);
        assert_eq!(selection_evaluated_bounds(&doc), (0.0, 0.0, 0.0, 0.0));
    }

    #[test]
    fn handle_rects_identity_transform_at_control_points() {
        use crate::geometry::element::{RectElem, CommonProps};
        // Rect 10,20,30,40 with no transform -> handles at the raw corners,
        // each of size HANDLE_DRAW_SIZE.
        let rect = Element::Rect(RectElem {
            x: 10.0, y: 20.0, width: 30.0, height: 40.0, rx: 0.0, ry: 0.0,
            fill: None, stroke: None, common: CommonProps::default(),
            fill_gradient: None, stroke_gradient: None,
        });
        let doc = hr_doc_with(rect);
        let rects = selection_handle_rects(&doc, &[0, 0]);
        let mut want = vec![(10.0, 20.0), (40.0, 20.0), (40.0, 60.0), (10.0, 60.0)];
        want.sort_by(|a, b| a.partial_cmp(b).unwrap());
        assert_eq!(hr_centers(&rects), want);
        for &(_x, _y, w, h) in &rects {
            assert_eq!((w, h), (HANDLE_DRAW_SIZE, HANDLE_DRAW_SIZE));
        }
    }

    #[test]
    fn handle_rects_scaled_element_move_but_do_not_grow() {
        // 100x100 rect at origin with a 2x scale transform. The corner
        // CENTERS are the TRANSFORMED corners (0,0),(200,0),(200,200),(0,200)
        // but each handle is still HANDLE_DRAW_SIZE, NOT 2x.
        let rect = hr_rect(Some(Transform::scale(2.0, 2.0)));
        let doc = hr_doc_with(rect);
        let rects = selection_handle_rects(&doc, &[0, 0]);
        let mut want = vec![(0.0, 0.0), (200.0, 0.0), (200.0, 200.0), (0.0, 200.0)];
        want.sort_by(|a, b| a.partial_cmp(b).unwrap());
        assert_eq!(hr_centers(&rects), want);
        for &(_x, _y, w, h) in &rects {
            assert_eq!((w, h), (HANDLE_DRAW_SIZE, HANDLE_DRAW_SIZE),
                "handle stays fixed size, NOT scaled by the element transform");
        }
    }

    #[test]
    fn handle_rects_no_handles_for_group() {
        use crate::geometry::element::{GroupElem, RectElem, CommonProps};
        let inner = std::rc::Rc::new(Element::Rect(RectElem {
            x: 0.0, y: 0.0, width: 10.0, height: 10.0, rx: 0.0, ry: 0.0,
            fill: None, stroke: None, common: CommonProps::default(),
            fill_gradient: None, stroke_gradient: None,
        }));
        let grp = Element::Group(GroupElem {
            children: vec![inner],
            isolated_blending: false, knockout_group: false,
            common: CommonProps::default(),
        });
        let doc = hr_doc_with(grp);
        assert!(selection_handle_rects(&doc, &[0, 0]).is_empty(),
            "containers (Group/Layer) carry no control-point handles");
    }

    // --- Selection outline scale (fixed-width outline pen) ---
    //
    // The selection OUTLINE trace is drawn UNDER the element transform; its
    // fixed pen width is divided by `selection_outline_scale(doc, path)`
    // (= sqrt(|det|) of the combined transform) so the element transform never
    // thickens it. 1x for no transform, 2x for a uniform 2x scale, geometric
    // mean for non-uniform. Mirrors the Python reference.

    #[test]
    fn outline_scale_identity_is_one() {
        // Rect with no transform -> scale 1.0.
        let doc = hr_doc_with(hr_rect(None));
        assert_eq!(selection_outline_scale(&doc, &[0, 0]), 1.0);
    }

    #[test]
    fn outline_scale_uniform_2x() {
        // Transform(2,0,0,2,0,0) -> det 4 -> sqrt = 2.0.
        let doc = hr_doc_with(hr_rect(Some(Transform::scale(2.0, 2.0))));
        assert_eq!(selection_outline_scale(&doc, &[0, 0]), 2.0);
    }

    #[test]
    fn outline_scale_nonuniform_geometric_mean() {
        // Transform(2,0,0,8,0,0) -> det 16 -> sqrt = 4.0.
        let doc = hr_doc_with(hr_rect(Some(Transform::scale(2.0, 8.0))));
        assert_eq!(selection_outline_scale(&doc, &[0, 0]), 4.0);
    }
}

// ═══════════════════════════════════════════════════════════════════════════
// THE CANVAS-PATH HARNESS (2026-08-28).
//
// ⛔ WHY THIS FILE ENDS WITH A SECOND TEST MODULE. Everything above runs on the
// host, where `HtmlCanvasElement` does not exist — so the mask pipeline's actual
// plumbing was, until now, COMPILE-VERIFIED ONLY. Defect D-β lived exactly
// there: a shared scratch canvas handed to a nested caller. The repair's
// bookkeeping (`ScratchDepth`) is driven natively above; THESE tests drive the
// part that needed a browser.
//
// This is the first cut of the harness the D-β write-up named as missing. It is
// deliberately small: one test that would have CAUGHT D-β, plus the control that
// makes it readable. A harness whose first test is the defect it was built for
// is worth more than a broad one whose arms have never failed.
// ═══════════════════════════════════════════════════════════════════════════
#[cfg(all(test, target_arch = "wasm32"))]
mod canvas_tests {
    use super::*;
    use wasm_bindgen_test::*;

    wasm_bindgen_test_configure!(run_in_browser);

    /// CONTROL. Without a reachable window/document the scratch cannot be built,
    /// and every assertion below would be vacuously true. If this fails, nothing
    /// else in this module is readable.
    #[wasm_bindgen_test]
    fn a_scratch_canvas_can_be_created_at_all() {
        let got = get_mask_scratch(0, 64, 64);
        assert!(got.is_some(), "no scratch canvas — the rest of this module is vacuous");
        let (c, _) = got.unwrap();
        assert_eq!((c.width(), c.height()), (64, 64));
    }

    /// ⛔ D-β ITSELF, IN THE BROWSER. Before the repair both acquisitions
    /// returned the SAME element, so the inner call's clear_rect wiped the
    /// outer's half-drawn buffer. This is the test that would have caught it.
    #[wasm_bindgen_test]
    fn nested_scratch_acquisitions_are_distinct_canvases() {
        let (outer, _) = get_mask_scratch(0, 64, 64).expect("outer scratch");
        let (inner, _) = get_mask_scratch(1, 64, 64).expect("inner scratch");
        assert!(
            !outer.is_same_node(Some(inner.as_ref())),
            "D-β: a nested acquisition received the OUTER's canvas — the inner \
             clear_rect would wipe a buffer still being drawn into"
        );
    }

    /// ...and the repair must not have become "allocate always": a sequential
    /// (non-nested) acquisition at the same depth REUSES the buffer, which is
    /// the frame cost the original singleton existed to avoid.
    #[wasm_bindgen_test]
    fn sequential_acquisitions_at_one_depth_reuse_the_canvas() {
        let (a, _) = get_mask_scratch(0, 64, 64).expect("first");
        let (b, _) = get_mask_scratch(0, 64, 64).expect("second");
        assert!(
            a.is_same_node(Some(b.as_ref())),
            "same depth must reuse the same canvas, not allocate a new one"
        );
    }

    /// THE CLOBBER, OBSERVED IN PIXELS rather than by element identity — the
    /// closest this harness gets to the user-visible defect. Draw into the
    /// depth-0 buffer, take a nested one and clear it, and the depth-0 pixel
    /// must survive.
    #[wasm_bindgen_test]
    fn a_nested_clear_does_not_wipe_the_outer_buffer() {
        let (_oc, octx) = get_mask_scratch(0, 8, 8).expect("outer");
        octx.set_fill_style_str("#ff0000");
        octx.fill_rect(0.0, 0.0, 8.0, 8.0);

        let (_ic, ictx) = get_mask_scratch(1, 8, 8).expect("inner");
        ictx.clear_rect(0.0, 0.0, 8.0, 8.0); // what the inner call does first

        let data = octx.get_image_data(0.0, 0.0, 1.0, 1.0).expect("readback");
        let px = data.data();
        assert_eq!(
            (px[0], px[3]),
            (255, 255),
            "D-β: the outer buffer was cleared by the nested acquisition"
        );
    }
}

// ═══════════════════════════════════════════════════════════════════════════
// PH4 — THE PRODUCTION CONVERSION, MEASURED IN A REAL BROWSER (2026-08-30).
//
// ⛔ THE BEFORE/AFTER IS A TEST, NOT A SCREENSHOT, and that is deliberate: a
// screenshot of a behaviour change is read once and believed; a test with both
// arms in it re-states the claim on every run and REDS if either arm moves.
// The Captain's condition was that this change land announced and legible —
// this module is where "what changes on screen" stops being prose.
// ═══════════════════════════════════════════════════════════════════════════
#[cfg(all(test, target_arch = "wasm32"))]
mod ph4_conversion_tests {
    use super::*;
    use crate::geometry::element::{CommonProps, Fill, GroupElem, Mask, RectElem};
    use std::rc::Rc;
    use wasm_bindgen_test::*;

    wasm_bindgen_test_configure!(run_in_browser);

    fn surface(w: u32, h: u32) -> (HtmlCanvasElement, CanvasRenderingContext2d) {
        let doc = web_sys::window().unwrap().document().unwrap();
        let c: HtmlCanvasElement = doc.create_element("canvas").unwrap().unchecked_into();
        c.set_width(w);
        c.set_height(h);
        let ctx: CanvasRenderingContext2d =
            c.get_context("2d").unwrap().unwrap().unchecked_into();
        (c, ctx)
    }

    fn alpha_at(ctx: &CanvasRenderingContext2d, x: f64, y: f64) -> u8 {
        ctx.get_image_data(x, y, 1.0, 1.0).unwrap().data()[3]
    }

    fn opaque_rect(x: f64, y: f64, w: f64, h: f64, color: Color) -> Element {
        Element::Rect(RectElem {
            x, y, width: w, height: h, rx: 0.0, ry: 0.0,
            fill: Some(Fill { color, opacity: 1.0 }),
            stroke: None,
            common: CommonProps::default(),
            fill_gradient: None,
            stroke_gradient: None,
        })
    }

    /// THE DISCRIMINATING DOCUMENT, and it has to be this shape.
    ///
    /// A masked group at opacity `own`, whose BODY IS TWO OVERLAPPING opaque
    /// rects, under a full-surface white mask (`LuminanceClipIn` with M = 1
    /// everywhere, so the mask contributes nothing and the alpha arithmetic is
    /// the only thing under test).
    ///
    /// ⛔ THE OVERLAP IS THE WHOLE INSTRUMENT. For a single-primitive body the
    /// legacy composite and the A6 bracket agree exactly, at `ancestors × own`
    /// — which is why this divergence survived the D-α repair and every golden
    /// since. They differ only where the element's own body overlaps itself.
    fn masked_overlapping_group(own: f64) -> Element {
        Element::Group(GroupElem {
            children: vec![
                Rc::new(opaque_rect(0.0, 0.0, 6.0, 8.0, Color::BLACK)),
                Rc::new(opaque_rect(2.0, 0.0, 6.0, 8.0, Color::BLACK)),
            ],
            common: CommonProps {
                opacity: own,
                mask: Some(Box::new(Mask {
                    subtree: Box::new(opaque_rect(0.0, 0.0, 8.0, 8.0, Color::WHITE)),
                    clip: true,
                    invert: false,
                    disabled: false,
                    linked: true,
                    unlink_transform: None,
                })),
                ..CommonProps::default()
            },
            isolated_blending: false,
            knockout_group: false,
        })
    }

    /// Render `elem` under an ancestor alpha of `parent`, either through the
    /// LEGACY composite (`before = true`) or through whatever
    /// [`draw_element_scaled`] routes to today. Returns
    /// `(alpha in the overlap, alpha outside it)`.
    fn render(elem: &Element, parent: f64, before: bool) -> (u8, u8) {
        let (_c, ctx) = surface(8, 8);
        ctx.set_global_alpha(parent);
        if before {
            let mask = elem.common().mask.as_deref().unwrap();
            let plan = mask_plan(mask).unwrap();
            draw_element_with_mask(&ctx, elem, mask, plan, Visibility::Preview, 1.0, 1.0);
        } else {
            draw_element_scaled(&ctx, elem, Visibility::Preview, 1.0, 1.0);
        }
        // x=3 is inside BOTH body rects; x=1 is inside only the first.
        (alpha_at(&ctx, 3.0, 4.0), alpha_at(&ctx, 1.0, 4.0))
    }

    fn close(got: u8, want: u8) -> bool {
        (got as i32 - want as i32).abs() <= 2
    }

    /// ⚠️⚠️ **THE RATIFIED A6 §6.2 BEHAVIOUR CHANGE, BEFORE AND AFTER, IN
    /// PIXELS.** This is the announcement.
    ///
    /// ⛔ AND IT IS NOT THE `own²` DEFECT. That was D-α; it was repaired in this
    /// file on 2026-08-24 (`mask_blit_alpha`) and a masked element has rendered
    /// at `ancestors × own` here ever since. The change this conversion lands is
    /// a different one, and it had to be measured to be named: **which factor
    /// is isolated.**
    ///
    /// ```text
    ///                          own opacity            ancestor product
    ///   legacy composite   per-primitive (compounds)  once, on the scratch
    ///   A6 bracket         once, at the composite     per-primitive (compounds)
    /// ```
    ///
    /// The contract pins group alpha as NON-isolated and A6 makes the masked
    /// element an ISOLATED layer carrying its own opacity. Production had both
    /// the wrong way round, so the two arms below SWAP their numbers when the
    /// same total alpha is moved from the ancestor to the element:
    ///
    /// ```text
    ///   parent 1.0 · own 0.5   overlap  191 (before)  ->  128 (after)
    ///   parent 0.5 · own 1.0   overlap  128 (before)  ->  191 (after)
    /// ```
    #[wasm_bindgen_test]
    fn a6_bracket_changes_what_a_masked_overlapping_body_renders() {
        // ARM 1 — the element carries the alpha.
        let doc = masked_overlapping_group(0.5);
        let (before_overlap, before_plain) = render(&doc, 1.0, true);
        let (after_overlap, after_plain) = render(&doc, 1.0, false);
        assert!(close(before_overlap, 191),
                "BEFORE: own 0.5 applied per-primitive compounds in the overlap \
                 to 1-(1-0.5)^2 = 0.75; got {before_overlap}");
        assert!(close(after_overlap, 128),
                "AFTER: own 0.5 rides the isolated layer and is spent once; \
                 got {after_overlap} (191 means the bracket did not fire)");

        // ⛔ THE UNCHANGED HALF, ASSERTED. Outside the overlap nothing moves —
        // so the difference above is the ISOLATION, not a global alpha shift.
        assert!(close(before_plain, 128) && close(after_plain, 128),
                "outside the overlap both paths give ancestors x own = 0.5; \
                 got before {before_plain}, after {after_plain}");

        // ARM 2 — THE SAME TOTAL ALPHA, MOVED TO THE ANCESTOR. The numbers swap,
        // which is what proves the two paths differ by WHICH factor is isolated
        // rather than by one of them being uniformly darker.
        let doc = masked_overlapping_group(1.0);
        let (before_overlap, _) = render(&doc, 0.5, true);
        let (after_overlap, _) = render(&doc, 0.5, false);
        assert!(close(before_overlap, 128),
                "BEFORE: the ancestor's 0.5 is applied ONCE to the finished \
                 scratch, so the overlap does not compound; got {before_overlap}");
        assert!(close(after_overlap, 191),
                "AFTER: the ancestor product is non-isolated and multiplies into \
                 every primitive, so the overlap compounds; got {after_overlap}");
    }

    /// ⛔ THE CONVERTED PATH UNDER A VIEW TRANSFORM — the arm that keeps the
    /// frame seed at the CALL SITE honest.
    ///
    /// `Canvas2dPainter::at_frame` is driven directly in `canvas2d.rs`, but
    /// that proves the constructor works, not that PRODUCTION uses it: swapping
    /// this call site back to `Canvas2dPainter::new` passes every other test in
    /// this repo, native and browser alike, because they all render at the
    /// identity. A control that does not run through the instrument checks
    /// nothing, so this one pans the view first.
    #[wasm_bindgen_test]
    fn a_converted_masked_element_lands_under_the_view_transform() {
        let (_c, ctx) = surface(16, 8);
        let _ = ctx.translate(8.0, 0.0);
        let doc = Element::Group(GroupElem {
            children: vec![Rc::new(opaque_rect(0.0, 0.0, 4.0, 8.0, Color::BLACK))],
            common: CommonProps {
                mask: Some(Box::new(Mask {
                    subtree: Box::new(opaque_rect(0.0, 0.0, 4.0, 8.0, Color::WHITE)),
                    clip: true, invert: false, disabled: false,
                    linked: true, unlink_transform: None,
                })),
                ..CommonProps::default()
            },
            isolated_blending: false,
            knockout_group: false,
        });
        draw_element_scaled(&ctx, &doc, Visibility::Preview, 1.0, 1.0);
        assert_eq!(alpha_at(&ctx, 10.0, 4.0), 255,
                   "the bracket must open in the frame the context is already in");
        assert_eq!(alpha_at(&ctx, 2.0, 4.0), 0,
                   "…and not at the identity origin, which is where an unframed \
                    layer surface puts it");
    }

    /// ⛔ THE FALLBACK IS SILENT BY DESIGN, SO IT IS ASSERTED HERE.
    ///
    /// A document the seam cannot express must render EXACTLY as it does today.
    /// The instrument is the same one above: the legacy arm and the live arm
    /// must AGREE, where the test above required them to differ. Without this,
    /// a fallback that had quietly stopped working would be invisible — every
    /// other test in this module would still pass.
    #[wasm_bindgen_test]
    fn a_document_the_seam_cannot_express_still_renders_the_legacy_way() {
        // A freeform gradient never crosses the seam (contract A5), so the whole
        // masked group must stay legacy.
        let mut legacy_child = RectElem {
            x: 2.0, y: 0.0, width: 6.0, height: 8.0, rx: 0.0, ry: 0.0,
            fill: Some(Fill { color: Color::BLACK, opacity: 1.0 }),
            stroke: None, common: CommonProps::default(),
            fill_gradient: None, stroke_gradient: None,
        };
        legacy_child.fill_gradient = Some(Box::new(crate::geometry::element::Gradient {
            gtype: crate::geometry::element::GradientType::Freeform,
            ..crate::geometry::element::Gradient::default()
        }));
        let doc = Element::Group(GroupElem {
            children: vec![
                Rc::new(opaque_rect(0.0, 0.0, 6.0, 8.0, Color::BLACK)),
                Rc::new(Element::Rect(legacy_child)),
            ],
            common: CommonProps {
                opacity: 0.5,
                mask: Some(Box::new(Mask {
                    subtree: Box::new(opaque_rect(0.0, 0.0, 8.0, 8.0, Color::WHITE)),
                    clip: true, invert: false, disabled: false,
                    linked: true, unlink_transform: None,
                })),
                ..CommonProps::default()
            },
            isolated_blending: false,
            knockout_group: false,
        });
        let legacy = render(&doc, 1.0, true);
        let live = render(&doc, 1.0, false);
        assert_eq!(legacy, live,
                   "a masked group with a freeform-gradient child must render \
                    identically to today -- the bracket would have DROPPED that \
                    child, which is why the router refuses it");
        // …and a control: the pixels are not simply both empty.
        assert!(legacy.1 > 0, "control: the legacy arm painted nothing, so the \
                               agreement above is vacuous");
    }
}

// ═══════════════════════════════════════════════════════════════════════════
// THE MASKED PATH'S COORDINATE FRAME — a shipped defect, found by PH4's
// instrument and fixed here (2026-08-30).
// ═══════════════════════════════════════════════════════════════════════════
#[cfg(all(test, target_arch = "wasm32"))]
mod ctx_transform_tests {
    use super::*;
    use crate::geometry::element::{CommonProps, Fill, Mask, RectElem};
    use wasm_bindgen_test::*;

    wasm_bindgen_test_configure!(run_in_browser);

    fn ctx_of(w: u32, h: u32) -> (HtmlCanvasElement, CanvasRenderingContext2d) {
        let doc = web_sys::window().unwrap().document().unwrap();
        let c: HtmlCanvasElement = doc.create_element("canvas").unwrap().unchecked_into();
        c.set_width(w);
        c.set_height(h);
        let ctx: CanvasRenderingContext2d =
            c.get_context("2d").unwrap().unwrap().unchecked_into();
        (c, ctx)
    }

    /// ⛔ THE PROPERTY THIS FILE READ FOR MONTHS IS ABSENT IN CHROME.
    ///
    /// Asserted rather than described, because it is the premise of the fix: if
    /// a future Chrome ships `currentTransform` this test reds and the next
    /// reader learns that the fallback below stopped being a fallback. Either
    /// direction is information; silence is not.
    #[wasm_bindgen_test]
    fn current_transform_is_absent_here_and_get_transform_is_not() {
        let (_c, ctx) = ctx_of(8, 8);
        let legacy = js_sys::Reflect::get(
            &ctx, &wasm_bindgen::JsValue::from_str("currentTransform"));
        assert!(legacy.map(|v| v.is_undefined()).unwrap_or(true),
                "currentTransform is now present -- read_ctx_transform's ordering \
                 comment is stale, not wrong");
        assert!(get_transform_object(&ctx).is_some(),
                "getTransform() is missing too: read_ctx_transform can only \
                 return None, and every masked element composites at identity");
    }

    /// The read itself, against a transform this test applied.
    #[wasm_bindgen_test]
    fn read_ctx_transform_returns_the_transform_that_was_applied() {
        let (_c, ctx) = ctx_of(8, 8);
        assert_eq!(read_ctx_transform(&ctx), Some((1.0, 0.0, 0.0, 1.0, 0.0, 0.0)),
                   "control: a fresh context must read as the identity");
        let _ = ctx.translate(3.0, 0.0);
        let _ = ctx.scale(2.0, 2.0);
        assert_eq!(read_ctx_transform(&ctx), Some((2.0, 0.0, 0.0, 2.0, 3.0, 0.0)));
    }

    /// ⛔⛔ THE SHIPPED DEFECT, IN PIXELS, ON THE PATH THAT SHIPS.
    ///
    /// `draw_element_with_mask` copies the main context's world transform onto
    /// its scratch with `if let Some(..) = read_ctx_transform(ctx)`. In Chrome
    /// that read returned `None`, the `if let` did not fire, and the scratch
    /// stayed at the IDENTITY while the main context carried the view
    /// transform — so a masked element was composited at the wrong place
    /// whenever the view was panned or zoomed. MEASURED before the repair: this
    /// document rendered at device x = 2 instead of x = 10.
    ///
    /// The failure is silent by construction: the fallback is a successful
    /// no-op, and this file's own docstring called it "a reasonable
    /// degradation". A degradation that moves the artwork is not one.
    #[wasm_bindgen_test]
    fn a_masked_element_composites_under_the_view_transform() {
        let (_c, ctx) = ctx_of(16, 8);
        // The view transform, exactly as the app applies one before drawing.
        let _ = ctx.translate(8.0, 0.0);
        let mk = |w: f64, col: Color| Element::Rect(RectElem {
            x: 0.0, y: 0.0, width: w, height: 8.0, rx: 0.0, ry: 0.0,
            fill: Some(Fill { color: col, opacity: 1.0 }), stroke: None,
            common: CommonProps::default(), fill_gradient: None, stroke_gradient: None,
        });
        let mut elem = mk(4.0, Color::BLACK);
        elem.common_mut().mask = Some(Box::new(Mask {
            subtree: Box::new(mk(4.0, Color::WHITE)),
            clip: true, invert: false, disabled: false,
            linked: true, unlink_transform: None,
        }));
        let mask = elem.common().mask.as_deref().unwrap().clone();
        let plan = mask_plan(&mask).unwrap();
        draw_element_with_mask(&ctx, &elem, &mask, plan, Visibility::Preview, 1.0, 1.0);

        let alpha = |x: f64| ctx.get_image_data(x, 4.0, 1.0, 1.0).unwrap().data()[3];
        assert_eq!(alpha(10.0), 255,
                   "the masked element must land where the VIEW puts it (x=0..4 \
                    in document space, +8 translate => device x=8..12)");
        assert_eq!(alpha(2.0), 0,
                   "…and nothing at the identity origin, which is where the \
                    identity-framed scratch used to put it");
    }
}
