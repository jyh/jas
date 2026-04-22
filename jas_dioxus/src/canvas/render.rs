//! Canvas2D rendering of document elements.
//!
//! Draws the document onto an HTML <canvas> via web_sys::CanvasRenderingContext2d.

use std::cell::RefCell;

use wasm_bindgen::JsCast;
use web_sys::{CanvasRenderingContext2d, HtmlCanvasElement};

use crate::document::artboard::{Artboard, ArtboardFill};
use crate::document::document::Document;
use crate::geometry::element::Visibility;
use crate::geometry::element::*;
use crate::geometry::measure::path_point_at_offset;
use crate::tools::tool::HANDLE_DRAW_SIZE;

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
fn blend_mode_css(mode: BlendMode) -> &'static str {
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

fn apply_fill(ctx: &CanvasRenderingContext2d, fill: Option<&Fill>) -> f64 {
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

/// Return value from apply_stroke: (opacity, alignment).
fn apply_stroke(ctx: &CanvasRenderingContext2d, stroke: Option<&Stroke>) -> (f64, StrokeAlign) {
    match stroke {
        Some(s) => {
            ctx.set_stroke_style_str(&css_color(&s.color));
            // Inside/outside use 2x width; the clip removes the unwanted half
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
            if !da.is_empty() {
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
            ctx.save();
            ctx.clip();
            ctx.stroke();
            ctx.restore();
        }
        StrokeAlign::Outside => {
            // The current path is still on the context. Add a huge rect
            // to the existing path (rect() doesn't clear it), then clip
            // with evenodd — this clips to everything OUTSIDE the shape.
            ctx.save();
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
            ctx.restore();
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
    // Opacity mask: when an element carries an active, supported mask,
    // redirect rendering through [draw_element_with_mask] which
    // composites the element against the mask's subtree on an
    // offscreen canvas. OPACITY.md §Rendering. Track C phase 1
    // supports ``clip: true`` (both invert values); ``clip: false``
    // and ``linked: false`` fall through to the plain path.
    if let Some(mask) = elem.common().mask.as_deref() {
        if let Some(op) = mask_composite_op(mask) {
            draw_element_with_mask(ctx, elem, mask, op, ancestor_vis, precision);
            return;
        }
    }
    draw_element_body(ctx, elem, ancestor_vis, precision);
}

// ---------------------------------------------------------------------------
// Opacity-mask compositing (OPACITY.md §Rendering)
// ---------------------------------------------------------------------------

/// Return the Canvas2D ``globalCompositeOperation`` string that
/// applies the given [Mask] to an element's offscreen image, or
/// ``None`` when the mask is inactive or its configuration isn't
/// yet supported by the renderer. The caller falls back to the
/// no-mask path when this returns ``None``.
///
/// Track C phase 1 supports ``clip: true`` only — the standard
/// "clip to mask shape" interpretation. ``clip: false`` (element
/// stays visible outside the mask shape) requires a more complex
/// two-pass composite and lands in a later phase. ``disabled`` is
/// treated as no-mask per the spec.
fn mask_composite_op(mask: &Mask) -> Option<&'static str> {
    if mask.disabled {
        return None;
    }
    if !mask.clip {
        return None;
    }
    Some(if mask.invert { "destination-out" } else { "destination-in" })
}

thread_local! {
    /// Reusable offscreen canvas for opacity-mask compositing.
    /// Created lazily on first use and resized to match the main
    /// canvas when the dimensions change. Kept as a module-level
    /// scratch buffer to avoid allocating a new DOM canvas per
    /// masked element per frame.
    static MASK_CANVAS: RefCell<Option<HtmlCanvasElement>> = const { RefCell::new(None) };
}

/// Read the six-component current transform from a Canvas2D
/// context via JS reflection on ``currentTransform``. Returns
/// ``None`` when the property isn't present or its fields aren't
/// numeric (which means we fall back to identity on the caller's
/// offscreen ctx — a reasonable degradation).
fn read_ctx_transform(
    ctx: &CanvasRenderingContext2d,
) -> Option<(f64, f64, f64, f64, f64, f64)> {
    let t = js_sys::Reflect::get(ctx, &wasm_bindgen::JsValue::from_str("currentTransform")).ok()?;
    let a = js_sys::Reflect::get(&t, &wasm_bindgen::JsValue::from_str("a")).ok()?.as_f64()?;
    let b = js_sys::Reflect::get(&t, &wasm_bindgen::JsValue::from_str("b")).ok()?.as_f64()?;
    let c = js_sys::Reflect::get(&t, &wasm_bindgen::JsValue::from_str("c")).ok()?.as_f64()?;
    let d = js_sys::Reflect::get(&t, &wasm_bindgen::JsValue::from_str("d")).ok()?.as_f64()?;
    let e = js_sys::Reflect::get(&t, &wasm_bindgen::JsValue::from_str("e")).ok()?.as_f64()?;
    let f = js_sys::Reflect::get(&t, &wasm_bindgen::JsValue::from_str("f")).ok()?.as_f64()?;
    Some((a, b, c, d, e, f))
}

/// Obtain (or lazily create) the scratch mask canvas, resized to
/// ``w x h``. Returns the canvas together with its 2D context.
/// Returns ``None`` if the DOM isn't reachable (e.g., non-browser
/// host or the canvas can't be created). Node is *not* appended
/// to the document — it lives only in memory.
fn get_mask_scratch(w: u32, h: u32) -> Option<(HtmlCanvasElement, CanvasRenderingContext2d)> {
    let canvas: HtmlCanvasElement = MASK_CANVAS.with(|cell| -> Option<HtmlCanvasElement> {
        if let Some(c) = cell.borrow().clone() {
            return Some(c);
        }
        let window = web_sys::window()?;
        let doc = window.document()?;
        let el = doc.create_element("canvas").ok()?;
        let c: HtmlCanvasElement = el.unchecked_into();
        *cell.borrow_mut() = Some(c.clone());
        Some(c)
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

/// Render ``elem`` on the main ``ctx`` with its opacity mask
/// composited in. The element body is drawn to a scratch
/// offscreen canvas at the same world transform as the main ctx;
/// the mask's subtree is drawn on top of it with the mask's
/// composite op (``destination-in`` / ``destination-out`` per
/// ``mask_composite_op``), leaving only the element pixels that
/// survive the mask. The scratch canvas is then copied onto the
/// main ctx at device coordinates.
fn draw_element_with_mask(
    ctx: &CanvasRenderingContext2d,
    elem: &Element,
    mask: &Mask,
    composite_op: &str,
    ancestor_vis: Visibility,
    precision: f64,
) {
    let main_canvas = ctx.canvas();
    let (w, h) = match &main_canvas {
        Some(c) => (c.width(), c.height()),
        None => {
            // No canvas reachable — fall back to the no-mask path.
            draw_element_body(ctx, elem, ancestor_vis, precision);
            return;
        }
    };
    if w == 0 || h == 0 {
        return;
    }
    let (off_canvas, off_ctx) = match get_mask_scratch(w, h) {
        Some(pair) => pair,
        None => {
            draw_element_body(ctx, elem, ancestor_vis, precision);
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
    // we don't recurse into ourselves) onto the offscreen canvas.
    draw_element_body(&off_ctx, elem, ancestor_vis, precision);

    // Pass 2: composite the mask subtree against the element's
    // pixels using ``destination-in`` (or ``destination-out`` when
    // the mask is inverted). The subtree is drawn in the element's
    // own coord system since ``linked: true`` is the phase-1 default.
    off_ctx.set_global_composite_operation(composite_op).ok();
    draw_element(&off_ctx, &mask.subtree, ancestor_vis, precision);

    // Copy the composited offscreen pixels onto the main ctx at
    // device coordinates (0, 0). The main ctx's alpha / blend_mode
    // will apply to the final blit, matching the non-mask path.
    ctx.save();
    ctx.set_transform(1.0, 0.0, 0.0, 1.0, 0.0, 0.0).ok();
    ctx.set_global_alpha(elem.opacity());
    ctx.set_global_composite_operation(blend_mode_css(elem.mode())).ok();
    ctx.draw_image_with_html_canvas_element(&off_canvas, 0.0, 0.0).ok();
    ctx.restore();
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
) {
    // Effective visibility is the minimum of the inherited (capping)
    // visibility and this element's own. Groups/Layers propagate the
    // cap down to their children; Invisible stops the recursion.
    let effective = std::cmp::min(ancestor_vis, elem.visibility());
    if effective == Visibility::Invisible {
        return;
    }
    let outline = effective == Visibility::Outline;

    ctx.save();
    apply_transform(ctx, elem.transform());
    let base_alpha = elem.opacity();
    ctx.set_global_alpha(base_alpha);
    ctx.set_global_composite_operation(blend_mode_css(elem.mode())).ok();

    match elem {
        Element::Line(e) => {
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
            // Arrowheads
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
        }
        Element::Rect(e) => {
            let (mut fill_op, mut stroke_op, mut stroke_align) = (1.0, 1.0, StrokeAlign::Center);
            if outline {
                apply_outline_style(ctx);
            } else {
                fill_op = apply_fill(ctx, e.fill.as_ref());
                (stroke_op, stroke_align) = apply_stroke(ctx, e.stroke.as_ref());
            }
            let has_fill = !outline && e.fill.is_some();
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
                    // Use path-based stroke for alignment support
                    ctx.begin_path();
                    ctx.rect(e.x, e.y, e.width, e.height);
                    stroke_aligned(ctx, stroke_align);
                }
            }
        }
        Element::Circle(e) => {
            let (mut fill_op, mut stroke_op, mut stroke_align) = (1.0, 1.0, StrokeAlign::Center);
            if outline {
                apply_outline_style(ctx);
            } else {
                fill_op = apply_fill(ctx, e.fill.as_ref());
                (stroke_op, stroke_align) = apply_stroke(ctx, e.stroke.as_ref());
            }
            ctx.begin_path();
            ctx.arc(e.cx, e.cy, e.r, 0.0, std::f64::consts::TAU).ok();
            if !outline && e.fill.is_some() {
                ctx.set_global_alpha(base_alpha * fill_op);
                ctx.fill();
            }
            if outline || e.stroke.is_some() {
                ctx.set_global_alpha(base_alpha * stroke_op);
                stroke_aligned(ctx, stroke_align);
            }
        }
        Element::Ellipse(e) => {
            let (mut fill_op, mut stroke_op, mut stroke_align) = (1.0, 1.0, StrokeAlign::Center);
            if outline {
                apply_outline_style(ctx);
            } else {
                fill_op = apply_fill(ctx, e.fill.as_ref());
                (stroke_op, stroke_align) = apply_stroke(ctx, e.stroke.as_ref());
            }
            ctx.begin_path();
            ctx.ellipse(e.cx, e.cy, e.rx, e.ry, 0.0, 0.0, std::f64::consts::TAU)
                .ok();
            if !outline && e.fill.is_some() {
                ctx.set_global_alpha(base_alpha * fill_op);
                ctx.fill();
            }
            if outline || e.stroke.is_some() {
                ctx.set_global_alpha(base_alpha * stroke_op);
                stroke_aligned(ctx, stroke_align);
            }
        }
        Element::Polyline(e) => {
            let (mut fill_op, mut stroke_op, mut stroke_align) = (1.0, 1.0, StrokeAlign::Center);
            if outline {
                apply_outline_style(ctx);
            } else {
                fill_op = apply_fill(ctx, e.fill.as_ref());
                (stroke_op, stroke_align) = apply_stroke(ctx, e.stroke.as_ref());
            }
            if !e.points.is_empty() {
                ctx.begin_path();
                ctx.move_to(e.points[0].0, e.points[0].1);
                for &(x, y) in &e.points[1..] {
                    ctx.line_to(x, y);
                }
                if !outline && e.fill.is_some() {
                    ctx.set_global_alpha(base_alpha * fill_op);
                    ctx.fill();
                }
                if outline || e.stroke.is_some() {
                    ctx.set_global_alpha(base_alpha * stroke_op);
                    stroke_aligned(ctx, stroke_align);
                }
            }
        }
        Element::Polygon(e) => {
            let (mut fill_op, mut stroke_op, mut stroke_align) = (1.0, 1.0, StrokeAlign::Center);
            if outline {
                apply_outline_style(ctx);
            } else {
                fill_op = apply_fill(ctx, e.fill.as_ref());
                (stroke_op, stroke_align) = apply_stroke(ctx, e.stroke.as_ref());
            }
            if !e.points.is_empty() {
                ctx.begin_path();
                ctx.move_to(e.points[0].0, e.points[0].1);
                for &(x, y) in &e.points[1..] {
                    ctx.line_to(x, y);
                }
                ctx.close_path();
                if !outline && e.fill.is_some() {
                    ctx.set_global_alpha(base_alpha * fill_op);
                    ctx.fill();
                }
                if outline || e.stroke.is_some() {
                    ctx.set_global_alpha(base_alpha * stroke_op);
                    stroke_aligned(ctx, stroke_align);
                }
            }
        }
        Element::Path(e) => {
            let (mut fill_op, mut stroke_op, mut stroke_align) = (1.0, 1.0, StrokeAlign::Center);
            if outline {
                apply_outline_style(ctx);
            } else {
                fill_op = apply_fill(ctx, e.fill.as_ref());
                (stroke_op, stroke_align) = apply_stroke(ctx, e.stroke.as_ref());
            }
            // Fill uses the original path
            if !outline && e.fill.is_some() {
                ctx.begin_path();
                build_path(ctx, &e.d);
                ctx.set_global_alpha(base_alpha * fill_op);
                ctx.fill();
            }
            // Stroke uses a shortened path to accommodate arrowheads
            if outline || e.stroke.is_some() {
                let shortened = if !outline {
                    if let Some(s) = e.stroke.as_ref() {
                        let start_sb = super::arrowheads::arrow_setback(
                            s.start_arrow.as_str(), s.width, s.start_arrow_scale);
                        let end_sb = super::arrowheads::arrow_setback(
                            s.end_arrow.as_str(), s.width, s.end_arrow_scale);
                        if start_sb > 0.0 || end_sb > 0.0 {
                            Some(super::arrowheads::shorten_path(&e.d, start_sb, end_sb))
                        } else { None }
                    } else { None }
                } else { None };
                let stroke_cmds = shortened.as_deref().unwrap_or(&e.d);
                ctx.set_global_alpha(base_alpha * stroke_op);
                if !outline && !e.width_points.is_empty() {
                    // Variable-width stroke via offset paths
                    if let Some(s) = e.stroke.as_ref() {
                        let color = css_color(&s.color);
                        crate::algorithms::offset_path::render_variable_width_path(
                            ctx, stroke_cmds, &e.width_points, &color, s.linecap,
                        );
                    }
                } else {
                    ctx.begin_path();
                    build_path(ctx, stroke_cmds);
                    stroke_aligned(ctx, stroke_align);
                }
            }
            // Arrowheads
            if !outline {
                if let Some(s) = e.stroke.as_ref() {
                    let color = css_color(&s.color);
                    let center = s.arrow_align == ArrowAlign::CenterAtEnd;
                    super::arrowheads::draw_arrowheads(
                        ctx, &e.d,
                        s.start_arrow.as_str(), s.end_arrow.as_str(),
                        s.start_arrow_scale, s.end_arrow_scale,
                        s.width, &color, center,
                    );
                }
            }
        }
        Element::Text(e) => {
            let fill_op = apply_fill(ctx, e.fill.as_ref());
            ctx.set_global_alpha(base_alpha * fill_op);
            // Multi-tspan text renders each tspan with its own
            // effective font (family / size / weight / style) and
            // text-decoration on a shared baseline. Single no-override
            // tspan falls through to the flat fast path below. First
            // pass covers the visible subset — font + decoration
            // overrides per tspan; per-tspan baseline-shift / rotate /
            // transform / dx / wrapping come in follow-ups.
            let is_flat = e.tspans.len() == 1 && e.tspans[0].has_no_overrides();
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
            // Illustrator's Character Rotation field): each glyph
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
            if needs_scale {
                ctx.save();
                ctx.translate(e.x, e.y).ok();
                ctx.scale(h_scale, v_scale).ok();
                ctx.translate(-e.x, -e.y).ok();
            }
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
                if rotate_rad == 0.0 {
                    // Fast path: single fill_text per line. The CSS
                    // letterSpacing property set earlier handles the
                    // inter-glyph advance.
                    ctx.fill_text(s, line_x, baseline).ok();
                } else {
                    // Per-glyph rotation: each glyph rotates around
                    // its own (cx, baseline). fill_text takes only a
                    // whole string, so draw one char at a time and
                    // advance cx manually. letter_spacing is folded
                    // into the advance the same way the fast path
                    // relies on CSS letterSpacing.
                    let mut cx = line_x;
                    for ch in s.chars() {
                        let ch_str = ch.to_string();
                        ctx.save();
                        ctx.translate(cx, baseline).ok();
                        ctx.rotate(rotate_rad).ok();
                        ctx.fill_text(&ch_str, 0.0, 0.0).ok();
                        ctx.restore();
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
                let counters = crate::algorithms::text_layout_paragraph::
                    compute_counters(&segments);
                for (si, seg) in segments.iter().enumerate() {
                    let style = match &seg.list_style {
                        Some(s) if !s.is_empty() => s,
                        _ => continue,
                    };
                    let marker = crate::algorithms::text_layout_paragraph::
                        marker_text(style, counters[si]);
                    if marker.is_empty() { continue; }
                    // First-line baseline: find the first layout line
                    // that starts at or after this segment's char range.
                    let first_line = layout.lines.iter()
                        .find(|l| l.start >= seg.char_start);
                    let baseline = match first_line {
                        Some(l) => e.y + l.baseline_y + y_shift,
                        None => continue,
                    };
                    let marker_x = e.x + seg.left_indent;
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
            if needs_scale {
                ctx.restore();
            }
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
                let fill_op = apply_fill(ctx, e.fill.as_ref());
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

                            ctx.save();
                            ctx.translate(px, py).ok();
                            ctx.rotate(angle).ok();
                            ctx.fill_text(&ch_str, -ch_width / 2.0, e.font_size * 0.35).ok();
                            ctx.restore();
                        }
                        offset += ch_width;
                    }
                }
            }
        }
        Element::Group(g) => {
            // Cap each child's effective visibility by our own
            // effective visibility (which already incorporates our
            // ancestor's cap).
            for child in &g.children {
                draw_element(ctx, child, effective, precision);
            }
        }
        Element::Layer(l) => {
            for child in &l.children {
                draw_element(ctx, child, effective, precision);
            }
        }
        Element::Live(v) => {
            match v {
                crate::geometry::live::LiveVariant::CompoundShape(cs) => {
                    let ps = cs.evaluate(precision);
                    let (mut fill_op, mut stroke_op, mut stroke_align) =
                        (1.0, 1.0, StrokeAlign::Center);
                    if outline {
                        apply_outline_style(ctx);
                    } else {
                        fill_op = apply_fill(ctx, cs.fill.as_ref());
                        (stroke_op, stroke_align) =
                            apply_stroke(ctx, cs.stroke.as_ref());
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
                        if !outline && cs.fill.is_some() {
                            ctx.set_global_alpha(base_alpha * fill_op);
                            ctx.fill();
                        }
                        if outline || cs.stroke.is_some() {
                            ctx.set_global_alpha(base_alpha * stroke_op);
                            stroke_aligned(ctx, stroke_align);
                        }
                    }
                }
            }
        }
    }
    ctx.restore();
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

        if has_rotate || has_transform {
            ctx.save();
            ctx.translate(cx, tspan_baseline).ok();
            if let Some(tr) = &t.transform {
                ctx.transform(tr.a, tr.b, tr.c, tr.d, tr.e, tr.f).ok();
            }
            if has_rotate {
                ctx.rotate(rotate_rad).ok();
            }
            ctx.fill_text(&t.content, 0.0, 0.0).ok();
        } else {
            ctx.fill_text(&t.content, cx, tspan_baseline).ok();
        }

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
        if has_rotate || has_transform {
            ctx.restore();
        }
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
        Element::Circle(e) => {
            ctx.move_to(e.cx + e.r, e.cy);
            ctx.arc(e.cx, e.cy, e.r, 0.0, std::f64::consts::TAU).ok();
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
        Element::Live(v) => match v {
            crate::geometry::live::LiveVariant::CompoundShape(cs) => {
                let ps = cs.evaluate(crate::geometry::live::DEFAULT_PRECISION);
                for ring in &ps {
                    if ring.len() < 2 { continue; }
                    ctx.move_to(ring[0].0, ring[0].1);
                    for &(x, y) in &ring[1..] {
                        ctx.line_to(x, y);
                    }
                    ctx.close_path();
                }
            }
        },
    }
}

fn draw_selection_overlays(ctx: &CanvasRenderingContext2d, doc: &Document) {
    let sel_color = "rgba(0, 120, 215, 0.9)";
    ctx.set_stroke_style_str(sel_color);
    ctx.set_line_width(1.0);

    for es in &doc.selection {
        let elem = match doc.get_element(&es.path) {
            Some(e) => e,
            None => continue,
        };

        // Text and TextPath get a bounding-box highlight instead of
        // a path trace. For area text the bbox aligns with the area
        // (that's what `bounds()` returns); for point text it wraps
        // the drawn glyphs; for TextPath it wraps the path the text
        // follows.
        let is_text_like = matches!(elem, Element::Text(_) | Element::TextPath(_));
        // Group/Layer selection highlights are produced by their
        // descendants, which are themselves in the selection when a
        // Group is picked (see `select_element`); the container
        // itself has nothing meaningful to outline.
        let is_container = matches!(elem, Element::Group(_) | Element::Layer(_));

        if is_text_like {
            let (bx, by, bw, bh) = elem.bounds();
            ctx.stroke_rect(bx, by, bw, bh);
        } else if !is_container {
            // Stroke the element's own path in bright blue.
            ctx.begin_path();
            trace_element_path(ctx, elem);
            ctx.stroke();

            // Draw the control-point squares. A selected CP (per the
            // `Partial` set, or any CP when kind is `All`) gets the
            // solid blue fill; others get white. On `All`, every CP
            // is filled blue — the whole element is grabbable.
            let cps = control_points(elem);
            let half = HANDLE_DRAW_SIZE / 2.0;
            // Re-apply stroke color (stroke() above may leave it as-is
            // but be explicit for the rect strokes below).
            ctx.set_stroke_style_str(sel_color);
            for (i, &(px, py)) in cps.iter().enumerate() {
                if es.kind.contains(i) {
                    ctx.set_fill_style_str(sel_color);
                } else {
                    ctx.set_fill_style_str("white");
                }
                ctx.fill_rect(px - half, py - half, HANDLE_DRAW_SIZE, HANDLE_DRAW_SIZE);
                ctx.stroke_rect(px - half, py - half, HANDLE_DRAW_SIZE, HANDLE_DRAW_SIZE);
            }
        }
        // Groups/Layers: nothing here.
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
        ArtboardFill::Transparent => None,
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
/// When `doc.artboard_options.fade_region_outside_artboard` is on,
/// paints a 50%-opacity canvas-gray mask over every screen region
/// not inside any artboard. The effect dims elements that live
/// outside the printable areas.
///
/// Implementation: fill the entire canvas in the fade color, then
/// punch out each artboard via the `destination-out` composite
/// operation (which subtracts the filled rect from the mask).
/// Canvas state is saved and restored so the composite change
/// doesn't leak into later passes.
fn draw_fade_overlay(
    ctx: &CanvasRenderingContext2d,
    doc: &Document,
    width: f64,
    height: f64,
) {
    if !doc.artboard_options.fade_region_outside_artboard {
        return;
    }
    if doc.artboards.is_empty() {
        return;
    }
    ctx.save();
    // Fill the full canvas with 50% theme-gray.
    ctx.set_fill_style_str("rgba(160,160,160,0.5)");
    ctx.fill_rect(0.0, 0.0, width, height);
    // Punch out each artboard.
    ctx.set_global_composite_operation("destination-out").ok();
    ctx.set_fill_style_str("rgba(0,0,0,1)");
    for ab in &doc.artboards {
        ctx.fill_rect(ab.x, ab.y, ab.width, ab.height);
    }
    ctx.restore();
}

fn draw_artboard_borders(ctx: &CanvasRenderingContext2d, doc: &Document) {
    ctx.set_stroke_style_str(ARTBOARD_BORDER_COLOR);
    ctx.set_line_width(1.0);
    for ab in &doc.artboards {
        ctx.stroke_rect(ab.x, ab.y, ab.width, ab.height);
    }
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
/// panel isn't wired (e.g., Rust Phase C not yet landed).
pub fn render(
    ctx: &CanvasRenderingContext2d,
    width: f64,
    height: f64,
    doc: &Document,
    precision: f64,
    panel_selected_artboards: &[String],
) {
    // Layer 1: canvas background.
    ctx.set_fill_style_str("white");
    ctx.fill_rect(0.0, 0.0, width, height);

    // Layer 2: artboard fills (list order, later wins in overlaps).
    draw_artboard_fills(ctx, doc);

    // Layer 3: document element tree.
    for layer in &doc.layers {
        draw_element(ctx, layer, Visibility::Preview, precision);
    }

    // Layer 4: fade overlay (dims regions outside any artboard).
    draw_fade_overlay(ctx, doc, width, height);

    // Layer 5: artboard borders (thin, above elements so they're
    // never occluded).
    draw_artboard_borders(ctx, doc);

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

    #[test]
    fn css_color_opaque_black() {
        let c = Color::Rgb { r: 0.0, g: 0.0, b: 0.0, a: 1.0 };
        assert_eq!(css_color(&c), "rgb(0,0,0)");
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

    // ── mask_composite_op (Track C phase 1) ────────────────

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
    fn mask_composite_op_clip_not_inverted_is_destination_in() {
        let m = test_mask(true, false, false);
        assert_eq!(mask_composite_op(&m), Some("destination-in"));
    }

    #[test]
    fn mask_composite_op_clip_inverted_is_destination_out() {
        let m = test_mask(true, true, false);
        assert_eq!(mask_composite_op(&m), Some("destination-out"));
    }

    #[test]
    fn mask_composite_op_disabled_is_none() {
        // disabled overrides both clip and invert: falls back to no
        // mask rendering per OPACITY.md § States.
        assert_eq!(mask_composite_op(&test_mask(true, false, true)), None);
        assert_eq!(mask_composite_op(&test_mask(true, true, true)), None);
        assert_eq!(mask_composite_op(&test_mask(false, false, true)), None);
    }

    #[test]
    fn mask_composite_op_no_clip_is_none_phase1() {
        // clip=false (element visible outside the mask shape) needs a
        // two-pass composite; not yet supported — falls back to no
        // mask. Phase 2 of Track C will handle this.
        assert_eq!(mask_composite_op(&test_mask(false, false, false)), None);
        assert_eq!(mask_composite_op(&test_mask(false, true, false)), None);
    }

    #[test]
    fn css_color_alpha_just_below_one() {
        let c = Color::Rgb { r: 0.0, g: 1.0, b: 0.0, a: 0.99 };
        assert_eq!(css_color(&c), "rgba(0,255,0,0.99)");
    }
}
