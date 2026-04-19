//! Canvas2D rendering of document elements.
//!
//! Draws the document onto an HTML <canvas> via web_sys::CanvasRenderingContext2d.

use web_sys::CanvasRenderingContext2d;

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

fn draw_element(ctx: &CanvasRenderingContext2d, elem: &Element, ancestor_vis: Visibility) {
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
            let leading_px = if e.line_height.is_empty() {
                effective_fs
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
                draw_element(ctx, child, effective);
            }
        }
        Element::Layer(l) => {
            for child in &l.children {
                draw_element(ctx, child, effective);
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
            // Handled separately.
        }
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
// Public render function
// ---------------------------------------------------------------------------

/// Render the entire document to the canvas.
pub fn render(ctx: &CanvasRenderingContext2d, width: f64, height: f64, doc: &Document) {
    // Clear
    ctx.set_fill_style_str("white");
    ctx.fill_rect(0.0, 0.0, width, height);

    // Draw all layers, starting with the most permissive ancestor
    // visibility. Each layer's own visibility caps it further, and
    // the cap propagates down to descendants.
    for layer in &doc.layers {
        draw_element(ctx, layer, Visibility::Preview);
    }

    // Draw selection overlays
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

    #[test]
    fn css_color_alpha_just_below_one() {
        let c = Color::Rgb { r: 0.0, g: 1.0, b: 0.0, a: 0.99 };
        assert_eq!(css_color(&c), "rgba(0,255,0,0.99)");
    }
}
