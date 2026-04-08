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
    if c.a >= 1.0 {
        format!(
            "rgb({},{},{})",
            (c.r * 255.0) as u8,
            (c.g * 255.0) as u8,
            (c.b * 255.0) as u8,
        )
    } else {
        format!(
            "rgba({},{},{},{})",
            (c.r * 255.0) as u8,
            (c.g * 255.0) as u8,
            (c.b * 255.0) as u8,
            c.a,
        )
    }
}

fn apply_fill(ctx: &CanvasRenderingContext2d, fill: Option<&Fill>) {
    match fill {
        Some(f) => ctx.set_fill_style_str(&css_color(&f.color)),
        None => ctx.set_fill_style_str("transparent"),
    }
}

fn apply_stroke(ctx: &CanvasRenderingContext2d, stroke: Option<&Stroke>) {
    match stroke {
        Some(s) => {
            ctx.set_stroke_style_str(&css_color(&s.color));
            ctx.set_line_width(s.width);
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
        }
        None => {
            ctx.set_stroke_style_str("transparent");
            ctx.set_line_width(0.0);
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

fn build_path(ctx: &CanvasRenderingContext2d, cmds: &[PathCommand]) {
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
    ctx.set_global_alpha(elem.opacity());

    match elem {
        Element::Line(e) => {
            if outline {
                apply_outline_style(ctx);
            } else {
                apply_stroke(ctx, e.stroke.as_ref());
            }
            ctx.begin_path();
            ctx.move_to(e.x1, e.y1);
            ctx.line_to(e.x2, e.y2);
            ctx.stroke();
        }
        Element::Rect(e) => {
            if outline {
                apply_outline_style(ctx);
            } else {
                apply_fill(ctx, e.fill.as_ref());
                apply_stroke(ctx, e.stroke.as_ref());
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
                    ctx.fill();
                }
                if has_stroke {
                    ctx.stroke();
                }
            } else {
                if has_fill {
                    ctx.fill_rect(e.x, e.y, e.width, e.height);
                }
                if has_stroke {
                    ctx.stroke_rect(e.x, e.y, e.width, e.height);
                }
            }
        }
        Element::Circle(e) => {
            if outline {
                apply_outline_style(ctx);
            } else {
                apply_fill(ctx, e.fill.as_ref());
                apply_stroke(ctx, e.stroke.as_ref());
            }
            ctx.begin_path();
            ctx.arc(e.cx, e.cy, e.r, 0.0, std::f64::consts::TAU).ok();
            if !outline && e.fill.is_some() {
                ctx.fill();
            }
            if outline || e.stroke.is_some() {
                ctx.stroke();
            }
        }
        Element::Ellipse(e) => {
            if outline {
                apply_outline_style(ctx);
            } else {
                apply_fill(ctx, e.fill.as_ref());
                apply_stroke(ctx, e.stroke.as_ref());
            }
            ctx.begin_path();
            ctx.ellipse(e.cx, e.cy, e.rx, e.ry, 0.0, 0.0, std::f64::consts::TAU)
                .ok();
            if !outline && e.fill.is_some() {
                ctx.fill();
            }
            if outline || e.stroke.is_some() {
                ctx.stroke();
            }
        }
        Element::Polyline(e) => {
            if outline {
                apply_outline_style(ctx);
            } else {
                apply_fill(ctx, e.fill.as_ref());
                apply_stroke(ctx, e.stroke.as_ref());
            }
            if !e.points.is_empty() {
                ctx.begin_path();
                ctx.move_to(e.points[0].0, e.points[0].1);
                for &(x, y) in &e.points[1..] {
                    ctx.line_to(x, y);
                }
                if !outline && e.fill.is_some() {
                    ctx.fill();
                }
                if outline || e.stroke.is_some() {
                    ctx.stroke();
                }
            }
        }
        Element::Polygon(e) => {
            if outline {
                apply_outline_style(ctx);
            } else {
                apply_fill(ctx, e.fill.as_ref());
                apply_stroke(ctx, e.stroke.as_ref());
            }
            if !e.points.is_empty() {
                ctx.begin_path();
                ctx.move_to(e.points[0].0, e.points[0].1);
                for &(x, y) in &e.points[1..] {
                    ctx.line_to(x, y);
                }
                ctx.close_path();
                if !outline && e.fill.is_some() {
                    ctx.fill();
                }
                if outline || e.stroke.is_some() {
                    ctx.stroke();
                }
            }
        }
        Element::Path(e) => {
            if outline {
                apply_outline_style(ctx);
            } else {
                apply_fill(ctx, e.fill.as_ref());
                apply_stroke(ctx, e.stroke.as_ref());
            }
            ctx.begin_path();
            build_path(ctx, &e.d);
            if !outline && e.fill.is_some() {
                ctx.fill();
            }
            if outline || e.stroke.is_some() {
                ctx.stroke();
            }
        }
        Element::Text(e) => {
            apply_fill(ctx, e.fill.as_ref());
            let font = format!("{} {} {}px {}", e.font_style, e.font_weight, e.font_size, e.font_family);
            ctx.set_font(&font);
            let measure = crate::tools::text_measure::make_measurer(&font, e.font_size);
            let max_w = if e.is_area_text() { e.width } else { 0.0 };
            let layout = crate::geometry::text_layout::layout(
                &e.content,
                max_w,
                e.font_size,
                measure.as_ref(),
            );
            let chars: Vec<char> = e.content.chars().collect();
            for line in &layout.lines {
                let s: String = chars[line.start..line.end].iter().collect();
                let s = s.trim_end_matches(|c: char| c == '\n');
                ctx.fill_text(s, e.x, e.y + line.baseline_y).ok();
            }
        }
        Element::TextPath(e) => {
            // Draw the path as a faint guide line
            ctx.set_stroke_style_str("rgba(180,180,180,0.4)");
            ctx.set_line_width(1.0);
            ctx.begin_path();
            build_path(ctx, &e.d);
            ctx.stroke();

            // Draw text along the path
            if !e.content.is_empty() && !e.d.is_empty() {
                apply_fill(ctx, e.fill.as_ref());
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
                    for ch in e.content.chars() {
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
