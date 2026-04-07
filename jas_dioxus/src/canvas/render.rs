//! Canvas2D rendering of document elements.
//!
//! Draws the document onto an HTML <canvas> via web_sys::CanvasRenderingContext2d.

use web_sys::CanvasRenderingContext2d;

use crate::document::document::{Document, SelectionKind};
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

fn draw_element(ctx: &CanvasRenderingContext2d, elem: &Element) {
    ctx.save();
    apply_transform(ctx, elem.transform());
    ctx.set_global_alpha(elem.opacity());

    match elem {
        Element::Line(e) => {
            apply_stroke(ctx, e.stroke.as_ref());
            ctx.begin_path();
            ctx.move_to(e.x1, e.y1);
            ctx.line_to(e.x2, e.y2);
            ctx.stroke();
        }
        Element::Rect(e) => {
            apply_fill(ctx, e.fill.as_ref());
            apply_stroke(ctx, e.stroke.as_ref());
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
                if e.fill.is_some() {
                    ctx.fill();
                }
                if e.stroke.is_some() {
                    ctx.stroke();
                }
            } else {
                if e.fill.is_some() {
                    ctx.fill_rect(e.x, e.y, e.width, e.height);
                }
                if e.stroke.is_some() {
                    ctx.stroke_rect(e.x, e.y, e.width, e.height);
                }
            }
        }
        Element::Circle(e) => {
            apply_fill(ctx, e.fill.as_ref());
            apply_stroke(ctx, e.stroke.as_ref());
            ctx.begin_path();
            ctx.arc(e.cx, e.cy, e.r, 0.0, std::f64::consts::TAU).ok();
            if e.fill.is_some() {
                ctx.fill();
            }
            if e.stroke.is_some() {
                ctx.stroke();
            }
        }
        Element::Ellipse(e) => {
            apply_fill(ctx, e.fill.as_ref());
            apply_stroke(ctx, e.stroke.as_ref());
            ctx.begin_path();
            ctx.ellipse(e.cx, e.cy, e.rx, e.ry, 0.0, 0.0, std::f64::consts::TAU)
                .ok();
            if e.fill.is_some() {
                ctx.fill();
            }
            if e.stroke.is_some() {
                ctx.stroke();
            }
        }
        Element::Polyline(e) => {
            apply_fill(ctx, e.fill.as_ref());
            apply_stroke(ctx, e.stroke.as_ref());
            if !e.points.is_empty() {
                ctx.begin_path();
                ctx.move_to(e.points[0].0, e.points[0].1);
                for &(x, y) in &e.points[1..] {
                    ctx.line_to(x, y);
                }
                if e.fill.is_some() {
                    ctx.fill();
                }
                if e.stroke.is_some() {
                    ctx.stroke();
                }
            }
        }
        Element::Polygon(e) => {
            apply_fill(ctx, e.fill.as_ref());
            apply_stroke(ctx, e.stroke.as_ref());
            if !e.points.is_empty() {
                ctx.begin_path();
                ctx.move_to(e.points[0].0, e.points[0].1);
                for &(x, y) in &e.points[1..] {
                    ctx.line_to(x, y);
                }
                ctx.close_path();
                if e.fill.is_some() {
                    ctx.fill();
                }
                if e.stroke.is_some() {
                    ctx.stroke();
                }
            }
        }
        Element::Path(e) => {
            apply_fill(ctx, e.fill.as_ref());
            apply_stroke(ctx, e.stroke.as_ref());
            ctx.begin_path();
            build_path(ctx, &e.d);
            if e.fill.is_some() {
                ctx.fill();
            }
            if e.stroke.is_some() {
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
            for child in &g.children {
                draw_element(ctx, child);
            }
        }
        Element::Layer(l) => {
            for child in &l.children {
                draw_element(ctx, child);
            }
        }
    }
    ctx.restore();
}

// ---------------------------------------------------------------------------
// Draw selection overlays
// ---------------------------------------------------------------------------

/// Whether to draw the blue bounding-box outline around each selected
/// element. Control-point handles are drawn regardless. Defaults to
/// `false` so the bbox does not clutter the canvas during normal
/// selection; flip to `true` to get the old behavior back.
pub const SHOW_SELECTION_BBOX: bool = false;

fn draw_selection_overlays(ctx: &CanvasRenderingContext2d, doc: &Document) {
    ctx.set_stroke_style_str("rgba(0, 120, 215, 0.8)");
    ctx.set_line_width(1.0);

    for es in &doc.selection {
        if let Some(elem) = doc.get_element(&es.path) {
            // Two visual conventions:
            //
            // - **CP-shape elements** (Path, TextPath, Polygon,
            //   Polyline, Line): always draw the control-point
            //   squares because the user can grab and drag them
            //   directly. No bounding box.
            //
            // - **Bounding-box-shape elements** (Rect, Circle,
            //   Ellipse, Text, TextPath, Group, Layer): the "control
            //   points" are bounding-box corners. Drawing them as
            //   little squares without the bounding box itself is
            //   confusing, so we draw both — the bbox outline and
            //   the corner squares — only when SHOW_SELECTION_BBOX
            //   is true. When false (the default) the canvas stays
            //   uncluttered and the user relies on the existing
            //   element rendering to tell what's selected.
            let cp_shape = matches!(
                elem,
                Element::Line(_)
                    | Element::Polyline(_)
                    | Element::Polygon(_)
                    | Element::Path(_)
            );

            if cp_shape {
                // Always draw the per-vertex/anchor squares.
                let cps = control_points(elem);
                let half = HANDLE_DRAW_SIZE / 2.0;
                for (i, &(px, py)) in cps.iter().enumerate() {
                    if es.kind.contains(i) {
                        ctx.set_fill_style_str("rgba(0, 120, 215, 0.8)");
                    } else {
                        ctx.set_fill_style_str("white");
                    }
                    ctx.fill_rect(px - half, py - half, HANDLE_DRAW_SIZE, HANDLE_DRAW_SIZE);
                    ctx.stroke_rect(px - half, py - half, HANDLE_DRAW_SIZE, HANDLE_DRAW_SIZE);
                }
            } else if matches!(es.kind, SelectionKind::Partial(_)) {
                // Bbox-shape element with a Partial(*) selection
                // (including Partial(empty)): draw the bbox-corner
                // squares so the user can see the grabbable handles,
                // colored per `contains(i)`. No bbox outline.
                let cps = control_points(elem);
                let half = HANDLE_DRAW_SIZE / 2.0;
                for (i, &(px, py)) in cps.iter().enumerate() {
                    if es.kind.contains(i) {
                        ctx.set_fill_style_str("rgba(0, 120, 215, 0.8)");
                    } else {
                        ctx.set_fill_style_str("white");
                    }
                    ctx.fill_rect(px - half, py - half, HANDLE_DRAW_SIZE, HANDLE_DRAW_SIZE);
                    ctx.stroke_rect(px - half, py - half, HANDLE_DRAW_SIZE, HANDLE_DRAW_SIZE);
                }
            } else if SHOW_SELECTION_BBOX {
                // Bbox-shape element AND the user opted in.
                let (bx, by, bw, bh) = elem.bounds();
                ctx.stroke_rect(bx, by, bw, bh);
                let cps = control_points(elem);
                let half = HANDLE_DRAW_SIZE / 2.0;
                for (i, &(px, py)) in cps.iter().enumerate() {
                    if es.kind.contains(i) {
                        ctx.set_fill_style_str("rgba(0, 120, 215, 0.8)");
                    } else {
                        ctx.set_fill_style_str("white");
                    }
                    ctx.fill_rect(px - half, py - half, HANDLE_DRAW_SIZE, HANDLE_DRAW_SIZE);
                    ctx.stroke_rect(px - half, py - half, HANDLE_DRAW_SIZE, HANDLE_DRAW_SIZE);
                }
            }
        }
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

    // Draw all layers
    for layer in &doc.layers {
        draw_element(ctx, layer);
    }

    // Draw selection overlays
    draw_selection_overlays(ctx, doc);
}
