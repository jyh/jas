//! Minimal PDF emitter (PRINT.md §Phase 1B).
//!
//! Writes a self-contained PDF 1.4 byte stream. Hand-rolled rather
//! than depending on a heavy library so the wasm32 target stays
//! light. Phase 1B coverage:
//!
//! - Artboards as pages (one page per artboard, in document order),
//!   unless `print_preferences.ignore_artboards = true` (then one
//!   page covering union of artboards).
//! - Per-page MediaBox = artboard rect.
//! - Element types: paths (fill + stroke), rect, line, circle,
//!   ellipse, polyline, polygon, groups, layers (transforms only).
//!   Text is basic single-tspan with the standard 14 PDF fonts
//!   (Helvetica only in Phase 1).
//! - Solid fills and strokes (no gradients), composite RGB only.
//! - `print_layers` enum filters layer subtrees on emit. Layer.print
//!   is not yet a field on LayerElem (LAYER_PRINT pending), so
//!   VisiblePrintable currently collapses to Visible until that
//!   data-model wire-up.
//! - `placement_x` / `placement_y` translate the page CTM.
//! - `scaling_mode` applies a uniform scale on the page CTM.
//!
//! Deferred to later phases: gradients, dash arrays beyond a basic
//! pattern, masks, blend modes ≠ Normal, multi-tspan text, images,
//! live elements, CMYK, transparency, marks/bleed area, separations,
//! `auto_rotate`, `transverse`, tiling.

use crate::document::artboard::Artboard;
use crate::document::document::Document;
use crate::document::print_preferences::{PrintLayers, ScalingMode};
use crate::geometry::element::*;

/// Convert a document to PDF bytes. The returned Vec<u8> is a valid
/// PDF 1.4 file: catalog → pages → page objects → content streams,
/// xref, trailer.
pub fn document_to_pdf(doc: &Document) -> Vec<u8> {
    let mut b = PdfBuilder::new();
    let pages = collect_pages(doc);
    let page_obj_ids = b.reserve_page_objs(pages.len());
    let pages_obj_id = b.next_id();
    let catalog_obj_id = b.next_id();

    b.write_header();

    let mut page_refs: Vec<usize> = Vec::with_capacity(pages.len());
    for (i, page) in pages.iter().enumerate() {
        let page_id = page_obj_ids[i];
        let content = build_page_content(doc, page);
        let content_id = b.write_content_stream(&content);
        b.write_page_obj(page_id, pages_obj_id, &page.media_box, content_id);
        page_refs.push(page_id);
    }

    b.write_pages_obj(pages_obj_id, &page_refs);
    b.write_catalog_obj(catalog_obj_id, pages_obj_id);
    b.write_xref_and_trailer(catalog_obj_id);
    b.into_bytes()
}

// ── Page collection ───────────────────────────────────────────

#[derive(Debug, Clone)]
struct Page {
    media_box: [f64; 4], // [llx, lly, urx, ury] in points
    src_x: f64,
    src_y: f64,
    src_w: f64,
    src_h: f64,
}

fn collect_pages(doc: &Document) -> Vec<Page> {
    if doc.print_preferences.ignore_artboards || doc.artboards.is_empty() {
        let (x, y, w, h) = if doc.artboards.is_empty() {
            (0.0, 0.0, 612.0, 792.0)
        } else {
            artboard_bounds_union(&doc.artboards)
        };
        return vec![Page {
            media_box: [0.0, 0.0, w, h],
            src_x: x,
            src_y: y,
            src_w: w,
            src_h: h,
        }];
    }
    doc.artboards
        .iter()
        .map(|ab| Page {
            media_box: [0.0, 0.0, ab.width, ab.height],
            src_x: ab.x,
            src_y: ab.y,
            src_w: ab.width,
            src_h: ab.height,
        })
        .collect()
}

fn artboard_bounds_union(abs: &[Artboard]) -> (f64, f64, f64, f64) {
    let mut min_x = f64::INFINITY;
    let mut min_y = f64::INFINITY;
    let mut max_x = f64::NEG_INFINITY;
    let mut max_y = f64::NEG_INFINITY;
    for ab in abs {
        min_x = min_x.min(ab.x);
        min_y = min_y.min(ab.y);
        max_x = max_x.max(ab.x + ab.width);
        max_y = max_y.max(ab.y + ab.height);
    }
    (min_x, min_y, max_x - min_x, max_y - min_y)
}

// ── Content-stream builder for one page ───────────────────────

fn build_page_content(doc: &Document, page: &Page) -> String {
    let mut s = String::new();
    let (sx, sy) = scaling_pair(doc);
    let (px, py) = placement_pair(doc);

    s.push_str("q\n");
    // Y-flip plus a translate to put origin at (0, page_h).
    push_cm(&mut s, 1.0, 0.0, 0.0, -1.0, 0.0, page.src_h);
    if px != 0.0 || py != 0.0 {
        push_cm(&mut s, 1.0, 0.0, 0.0, 1.0, px, py);
    }
    if sx != 1.0 || sy != 1.0 {
        push_cm(&mut s, sx, 0.0, 0.0, sy, 0.0, 0.0);
    }
    if page.src_x != 0.0 || page.src_y != 0.0 {
        push_cm(&mut s, 1.0, 0.0, 0.0, 1.0, -page.src_x, -page.src_y);
    }

    for layer in &doc.layers {
        emit_element(&mut s, layer, &doc.print_preferences.print_layers);
    }
    s.push_str("Q\n");
    s
}

fn scaling_pair(doc: &Document) -> (f64, f64) {
    match doc.print_preferences.scaling_mode {
        ScalingMode::DoNotScale | ScalingMode::FitToPage => (1.0, 1.0),
        ScalingMode::Custom => {
            let s = doc.print_preferences.custom_scale / 100.0;
            (s, s)
        }
    }
}

fn placement_pair(doc: &Document) -> (f64, f64) {
    (
        doc.print_preferences.placement_x,
        doc.print_preferences.placement_y,
    )
}

// ── Element walk and emit ─────────────────────────────────────

fn layer_passes_filter(layer: &LayerElem, filter: &PrintLayers) -> bool {
    match filter {
        PrintLayers::All => true,
        // VisiblePrintable would also gate on `Layer.print`; that
        // field is pending the LAYER_PRINT data wire-up, so for now
        // it's identical to Visible.
        PrintLayers::Visible | PrintLayers::VisiblePrintable => {
            layer.common.visibility != Visibility::Invisible
        }
    }
}

fn emit_element(out: &mut String, el: &Element, filter: &PrintLayers) {
    match el {
        Element::Layer(le) => {
            if !layer_passes_filter(le, filter) {
                return;
            }
            out.push_str("q\n");
            emit_common_transform(out, &le.common);
            for child in &le.children {
                emit_element(out, child, filter);
            }
            out.push_str("Q\n");
        }
        Element::Group(g) => {
            if g.common.visibility == Visibility::Invisible {
                return;
            }
            out.push_str("q\n");
            emit_common_transform(out, &g.common);
            for child in &g.children {
                emit_element(out, child, filter);
            }
            out.push_str("Q\n");
        }
        Element::Path(p) => emit_paint(out, &p.common, p.fill.as_ref(), p.stroke.as_ref(), |s| {
            emit_path_geom(s, &p.d);
        }),
        Element::Rect(r) => emit_paint(out, &r.common, r.fill.as_ref(), r.stroke.as_ref(), |s| {
            push_num(s, r.x);
            push_num(s, r.y);
            push_num(s, r.width);
            push_num(s, r.height);
            s.push_str("re\n");
        }),
        Element::Line(l) => emit_paint(out, &l.common, None, l.stroke.as_ref(), |s| {
            push_num(s, l.x1);
            push_num(s, l.y1);
            s.push_str("m\n");
            push_num(s, l.x2);
            push_num(s, l.y2);
            s.push_str("l\n");
        }),
        Element::Circle(c) => emit_paint(out, &c.common, c.fill.as_ref(), c.stroke.as_ref(), |s| {
            emit_circle(s, c.cx, c.cy, c.r, c.r);
        }),
        Element::Ellipse(e) => emit_paint(out, &e.common, e.fill.as_ref(), e.stroke.as_ref(), |s| {
            emit_circle(s, e.cx, e.cy, e.rx, e.ry);
        }),
        Element::Polyline(pl) => emit_paint(out, &pl.common, pl.fill.as_ref(), pl.stroke.as_ref(), |s| {
            emit_polyline(s, &pl.points, false);
        }),
        Element::Polygon(pg) => emit_paint(out, &pg.common, pg.fill.as_ref(), pg.stroke.as_ref(), |s| {
            emit_polyline(s, &pg.points, true);
        }),
        Element::Text(t) => emit_text(out, t),
        // Phase 1B deferral list: TextPath, Live (compound shape,
        // brushes etc evaluated geometry).
        Element::TextPath(_) | Element::Live(_) => {}
    }
}

fn emit_common_transform(out: &mut String, c: &CommonProps) {
    if let Some(t) = &c.transform {
        push_cm(out, t.a, t.b, t.c, t.d, t.e, t.f);
    }
}

/// Emit a paint sequence: set fill/stroke colors, push the geometry
/// generator, then emit the appropriate paint operator.
fn emit_paint<F: FnOnce(&mut String)>(
    out: &mut String,
    c: &CommonProps,
    fill: Option<&Fill>,
    stroke: Option<&Stroke>,
    geom: F,
) {
    if c.visibility == Visibility::Invisible {
        return;
    }
    if fill.is_none() && stroke.is_none() {
        return;
    }
    out.push_str("q\n");
    emit_common_transform(out, c);
    if let Some(f) = fill {
        let (r, g, b) = color_rgb(&f.color);
        push_num(out, r);
        push_num(out, g);
        push_num(out, b);
        out.push_str("rg\n");
    }
    if let Some(s) = stroke {
        let (r, g, b) = color_rgb(&s.color);
        push_num(out, r);
        push_num(out, g);
        push_num(out, b);
        out.push_str("RG\n");
        push_num(out, s.width);
        out.push_str("w\n");
    }
    geom(out);
    let op = match (fill.is_some(), stroke.is_some()) {
        (true, true) => "B\n",
        (true, false) => "f\n",
        (false, true) => "S\n",
        _ => "n\n",
    };
    out.push_str(op);
    out.push_str("Q\n");
}

fn emit_path_geom(out: &mut String, commands: &[PathCommand]) {
    // Track current point so SmoothCurveTo / SmoothQuadTo can compute
    // the reflected control point; track previous control point for
    // the smooth variants per SVG 1.1 §8.3.6.
    let mut cur: (f64, f64) = (0.0, 0.0);
    let mut prev_cubic_cp: Option<(f64, f64)> = None;
    let mut prev_quad_cp: Option<(f64, f64)> = None;

    for cmd in commands {
        match cmd {
            PathCommand::MoveTo { x, y } => {
                push_num(out, *x);
                push_num(out, *y);
                out.push_str("m\n");
                cur = (*x, *y);
                prev_cubic_cp = None;
                prev_quad_cp = None;
            }
            PathCommand::LineTo { x, y } => {
                push_num(out, *x);
                push_num(out, *y);
                out.push_str("l\n");
                cur = (*x, *y);
                prev_cubic_cp = None;
                prev_quad_cp = None;
            }
            PathCommand::CurveTo { x1, y1, x2, y2, x, y } => {
                push_num(out, *x1);
                push_num(out, *y1);
                push_num(out, *x2);
                push_num(out, *y2);
                push_num(out, *x);
                push_num(out, *y);
                out.push_str("c\n");
                cur = (*x, *y);
                prev_cubic_cp = Some((*x2, *y2));
                prev_quad_cp = None;
            }
            PathCommand::SmoothCurveTo { x2, y2, x, y } => {
                let (x1, y1) = match prev_cubic_cp {
                    Some((px, py)) => (2.0 * cur.0 - px, 2.0 * cur.1 - py),
                    None => cur,
                };
                push_num(out, x1);
                push_num(out, y1);
                push_num(out, *x2);
                push_num(out, *y2);
                push_num(out, *x);
                push_num(out, *y);
                out.push_str("c\n");
                cur = (*x, *y);
                prev_cubic_cp = Some((*x2, *y2));
                prev_quad_cp = None;
            }
            PathCommand::QuadTo { x1, y1, x, y } => {
                // Convert quad → cubic so we don't depend on PDF's
                // 'v' operator reading "current point" reliably across
                // viewers.
                let (cp1, cp2) = quad_to_cubic_cps(cur, (*x1, *y1), (*x, *y));
                push_num(out, cp1.0);
                push_num(out, cp1.1);
                push_num(out, cp2.0);
                push_num(out, cp2.1);
                push_num(out, *x);
                push_num(out, *y);
                out.push_str("c\n");
                cur = (*x, *y);
                prev_cubic_cp = None;
                prev_quad_cp = Some((*x1, *y1));
            }
            PathCommand::SmoothQuadTo { x, y } => {
                let q_ctrl = match prev_quad_cp {
                    Some((px, py)) => (2.0 * cur.0 - px, 2.0 * cur.1 - py),
                    None => cur,
                };
                let (cp1, cp2) = quad_to_cubic_cps(cur, q_ctrl, (*x, *y));
                push_num(out, cp1.0);
                push_num(out, cp1.1);
                push_num(out, cp2.0);
                push_num(out, cp2.1);
                push_num(out, *x);
                push_num(out, *y);
                out.push_str("c\n");
                cur = (*x, *y);
                prev_cubic_cp = None;
                prev_quad_cp = Some(q_ctrl);
            }
            PathCommand::ArcTo { x, y, .. } => {
                // Phase 1B deferral: emit a straight line to the
                // endpoint as a degenerate fallback. Real arc
                // flattening lives with the arc-extrema gap backlog
                // item.
                push_num(out, *x);
                push_num(out, *y);
                out.push_str("l\n");
                cur = (*x, *y);
                prev_cubic_cp = None;
                prev_quad_cp = None;
            }
            PathCommand::ClosePath => {
                out.push_str("h\n");
                prev_cubic_cp = None;
                prev_quad_cp = None;
            }
        }
    }
}

fn quad_to_cubic_cps(
    p0: (f64, f64),
    pc: (f64, f64),
    p1: (f64, f64),
) -> ((f64, f64), (f64, f64)) {
    // Standard quad → cubic conversion: cp1 = p0 + 2/3 (pc - p0),
    // cp2 = p1 + 2/3 (pc - p1).
    let cp1 = (
        p0.0 + 2.0 / 3.0 * (pc.0 - p0.0),
        p0.1 + 2.0 / 3.0 * (pc.1 - p0.1),
    );
    let cp2 = (
        p1.0 + 2.0 / 3.0 * (pc.0 - p1.0),
        p1.1 + 2.0 / 3.0 * (pc.1 - p1.1),
    );
    (cp1, cp2)
}

/// Approximate a circle/ellipse with four cubic Beziers using the
/// classic 0.5522847498 magic constant.
fn emit_circle(out: &mut String, cx: f64, cy: f64, rx: f64, ry: f64) {
    const K: f64 = 0.5522847498307933;
    let cox = rx * K;
    let coy = ry * K;
    push_num(out, cx + rx);
    push_num(out, cy);
    out.push_str("m\n");
    push_num(out, cx + rx);
    push_num(out, cy + coy);
    push_num(out, cx + cox);
    push_num(out, cy + ry);
    push_num(out, cx);
    push_num(out, cy + ry);
    out.push_str("c\n");
    push_num(out, cx - cox);
    push_num(out, cy + ry);
    push_num(out, cx - rx);
    push_num(out, cy + coy);
    push_num(out, cx - rx);
    push_num(out, cy);
    out.push_str("c\n");
    push_num(out, cx - rx);
    push_num(out, cy - coy);
    push_num(out, cx - cox);
    push_num(out, cy - ry);
    push_num(out, cx);
    push_num(out, cy - ry);
    out.push_str("c\n");
    push_num(out, cx + cox);
    push_num(out, cy - ry);
    push_num(out, cx + rx);
    push_num(out, cy - coy);
    push_num(out, cx + rx);
    push_num(out, cy);
    out.push_str("c\n");
    out.push_str("h\n");
}

fn emit_polyline(out: &mut String, points: &[(f64, f64)], close: bool) {
    if points.is_empty() {
        return;
    }
    push_num(out, points[0].0);
    push_num(out, points[0].1);
    out.push_str("m\n");
    for p in &points[1..] {
        push_num(out, p.0);
        push_num(out, p.1);
        out.push_str("l\n");
    }
    if close {
        out.push_str("h\n");
    }
}

fn emit_text(out: &mut String, t: &TextElem) {
    if t.common.visibility == Visibility::Invisible {
        return;
    }
    let s: String = t.tspans.iter().map(|sp| sp.content.as_str()).collect();
    if s.is_empty() {
        return;
    }
    let (r, g, b) = t
        .fill
        .as_ref()
        .map(|f| color_rgb(&f.color))
        .unwrap_or((0.0, 0.0, 0.0));
    out.push_str("q\n");
    emit_common_transform(out, &t.common);
    push_num(out, r);
    push_num(out, g);
    push_num(out, b);
    out.push_str("rg\n");
    out.push_str("BT\n");
    let size = t.font_size.max(1.0);
    out.push_str("/F1 ");
    push_num(out, size);
    out.push_str("Tf\n");
    // Re-flip the Y axis locally so glyphs read normally despite the
    // page-CTM flip.
    push_num(out, t.x);
    push_num(out, t.y);
    out.push_str("Td\n");
    out.push_str("1 0 0 -1 0 0 Tm\n");
    out.push('(');
    out.push_str(&pdf_escape(&s));
    out.push_str(") Tj\n");
    out.push_str("ET\n");
    out.push_str("Q\n");
}

fn pdf_escape(s: &str) -> String {
    let mut out = String::with_capacity(s.len());
    for c in s.chars() {
        match c {
            '(' => out.push_str("\\("),
            ')' => out.push_str("\\)"),
            '\\' => out.push_str("\\\\"),
            '\n' => out.push_str("\\n"),
            '\r' => out.push_str("\\r"),
            '\t' => out.push_str("\\t"),
            c if (c as u32) < 32 || (c as u32) > 126 => {
                // Phase 1B: replace non-ASCII with '?' rather than
                // emit a CJK-capable font; full Unicode support waits
                // on font embedding (Phase 4: Graphics tab).
                out.push('?');
            }
            c => out.push(c),
        }
    }
    out
}

fn color_rgb(c: &Color) -> (f64, f64, f64) {
    match c {
        Color::Rgb { r, g, b, .. } => (*r, *g, *b),
        Color::Hsb { .. } | Color::Cmyk { .. } => (0.0, 0.0, 0.0),
    }
}

fn push_num(s: &mut String, n: f64) {
    let v = if n.is_finite() { n } else { 0.0 };
    let rounded = (v * 10000.0).round() / 10000.0;
    if rounded == rounded.trunc() {
        s.push_str(&format!("{:.0} ", rounded));
    } else {
        let f = format!("{:.4}", rounded);
        let f = f.trim_end_matches('0').trim_end_matches('.');
        s.push_str(f);
        s.push(' ');
    }
}

fn push_cm(s: &mut String, a: f64, b: f64, c: f64, d: f64, e: f64, f: f64) {
    push_num(s, a);
    push_num(s, b);
    push_num(s, c);
    push_num(s, d);
    push_num(s, e);
    push_num(s, f);
    s.push_str("cm\n");
}

// ── PDF object table builder ──────────────────────────────────

struct PdfBuilder {
    bytes: Vec<u8>,
    /// `offsets[id - 1]` = byte offset of obj `id`. Reserved IDs
    /// have `None` until written.
    offsets: Vec<Option<usize>>,
    next: usize, // next free obj id
}

impl PdfBuilder {
    fn new() -> Self {
        Self {
            bytes: Vec::new(),
            offsets: Vec::new(),
            next: 1,
        }
    }

    fn next_id(&mut self) -> usize {
        let id = self.next;
        self.next += 1;
        self.offsets.push(None);
        id
    }

    fn reserve_page_objs(&mut self, n: usize) -> Vec<usize> {
        (0..n).map(|_| self.next_id()).collect()
    }

    fn write_header(&mut self) {
        // Binary marker per PDF 32000-1 §7.5.2.
        self.bytes
            .extend_from_slice(b"%PDF-1.4\n%\xC1\xC2\xC3\xC4\n");
    }

    fn record_offset(&mut self, id: usize) {
        let pos = self.bytes.len();
        self.offsets[id - 1] = Some(pos);
    }

    fn write_content_stream(&mut self, content: &str) -> usize {
        let id = self.next_id();
        self.record_offset(id);
        let header = format!("{} 0 obj\n<< /Length {} >>\nstream\n", id, content.len());
        self.bytes.extend_from_slice(header.as_bytes());
        self.bytes.extend_from_slice(content.as_bytes());
        self.bytes.extend_from_slice(b"\nendstream\nendobj\n");
        id
    }

    fn write_page_obj(
        &mut self,
        id: usize,
        parent: usize,
        media_box: &[f64; 4],
        contents: usize,
    ) {
        self.record_offset(id);
        let body = format!(
            "{} 0 obj\n<< /Type /Page /Parent {} 0 R /MediaBox [{} {} {} {}] /Contents {} 0 R /Resources << /Font << /F1 << /Type /Font /Subtype /Type1 /BaseFont /Helvetica >> >> >> >>\nendobj\n",
            id, parent,
            fmt_pdf_num(media_box[0]), fmt_pdf_num(media_box[1]),
            fmt_pdf_num(media_box[2]), fmt_pdf_num(media_box[3]),
            contents,
        );
        self.bytes.extend_from_slice(body.as_bytes());
    }

    fn write_pages_obj(&mut self, id: usize, kids: &[usize]) {
        self.record_offset(id);
        let kids_str = kids
            .iter()
            .map(|k| format!("{} 0 R", k))
            .collect::<Vec<_>>()
            .join(" ");
        let body = format!(
            "{} 0 obj\n<< /Type /Pages /Kids [{}] /Count {} >>\nendobj\n",
            id, kids_str, kids.len()
        );
        self.bytes.extend_from_slice(body.as_bytes());
    }

    fn write_catalog_obj(&mut self, id: usize, pages: usize) {
        self.record_offset(id);
        let body = format!(
            "{} 0 obj\n<< /Type /Catalog /Pages {} 0 R >>\nendobj\n",
            id, pages
        );
        self.bytes.extend_from_slice(body.as_bytes());
    }

    fn write_xref_and_trailer(&mut self, root: usize) {
        let xref_offset = self.bytes.len();
        let n = self.offsets.len();
        let header = format!("xref\n0 {}\n0000000000 65535 f \n", n + 1);
        self.bytes.extend_from_slice(header.as_bytes());
        for off in &self.offsets {
            let line = format!("{:010} 00000 n \n", off.unwrap_or(0));
            self.bytes.extend_from_slice(line.as_bytes());
        }
        let trailer = format!(
            "trailer\n<< /Size {} /Root {} 0 R >>\nstartxref\n{}\n%%EOF\n",
            n + 1, root, xref_offset
        );
        self.bytes.extend_from_slice(trailer.as_bytes());
    }

    fn into_bytes(self) -> Vec<u8> {
        self.bytes
    }
}

fn fmt_pdf_num(n: f64) -> String {
    let v = if n.is_finite() { n } else { 0.0 };
    let rounded = (v * 10000.0).round() / 10000.0;
    if rounded == rounded.trunc() {
        format!("{:.0}", rounded)
    } else {
        let f = format!("{:.4}", rounded);
        f.trim_end_matches('0').trim_end_matches('.').to_string()
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::document::artboard::Artboard;
    use crate::document::print_preferences::PrintLayers;
    use std::rc::Rc;

    fn pdf_starts_with_header(bytes: &[u8]) -> bool {
        bytes.starts_with(b"%PDF-1.4\n")
    }

    fn pdf_ends_with_eof(bytes: &[u8]) -> bool {
        bytes.ends_with(b"%%EOF\n")
    }

    #[test]
    fn pdf_smoke_default_doc_is_valid_envelope() {
        let doc = Document::default();
        let bytes = document_to_pdf(&doc);
        assert!(pdf_starts_with_header(&bytes));
        assert!(pdf_ends_with_eof(&bytes));
        let s = String::from_utf8_lossy(&bytes);
        assert!(s.contains("/Type /Catalog"));
        assert!(s.contains("/Type /Pages"));
        assert!(s.contains("/Type /Page "));
        assert!(s.contains("xref"));
    }

    #[test]
    fn pdf_one_artboard_yields_one_page() {
        let doc = Document::default();
        let bytes = document_to_pdf(&doc);
        let s = String::from_utf8_lossy(&bytes);
        assert!(s.contains("/Count 1"), "expected /Count 1 in:\n{}", s);
    }

    #[test]
    fn pdf_n_artboards_yields_n_pages() {
        let mut doc = Document::default();
        doc.artboards = vec![
            Artboard {
                x: 0.0, y: 0.0, width: 100.0, height: 100.0,
                ..Artboard::default_with_id("a".into())
            },
            Artboard {
                x: 0.0, y: 200.0, width: 200.0, height: 200.0,
                ..Artboard::default_with_id("b".into())
            },
            Artboard {
                x: 0.0, y: 500.0, width: 50.0, height: 50.0,
                ..Artboard::default_with_id("c".into())
            },
        ];
        let bytes = document_to_pdf(&doc);
        let s = String::from_utf8_lossy(&bytes);
        assert!(s.contains("/Count 3"), "expected /Count 3");
        let count = s.matches("/Type /Page ").count();
        assert_eq!(count, 3, "expected 3 /Type /Page entries");
    }

    #[test]
    fn pdf_ignore_artboards_collapses_to_one_page() {
        let mut doc = Document::default();
        doc.artboards = vec![
            Artboard {
                x: 0.0, y: 0.0, width: 100.0, height: 100.0,
                ..Artboard::default_with_id("a".into())
            },
            Artboard {
                x: 200.0, y: 200.0, width: 200.0, height: 200.0,
                ..Artboard::default_with_id("b".into())
            },
        ];
        doc.print_preferences.ignore_artboards = true;
        let bytes = document_to_pdf(&doc);
        let s = String::from_utf8_lossy(&bytes);
        assert!(s.contains("/Count 1"));
        assert!(
            s.contains("/MediaBox [0 0 400 400]"),
            "expected union media box; got:\n{}",
            s
        );
    }

    #[test]
    fn pdf_print_layers_filters_invisible() {
        let mut doc = Document::default();
        doc.layers.push(Element::Layer(LayerElem {
            children: vec![Rc::new(Element::Rect(RectElem {
                x: 10.0,
                y: 10.0,
                width: 50.0,
                height: 50.0,
                rx: 0.0,
                ry: 0.0,
                fill: Some(Fill {
                    color: Color::Rgb { r: 1.0, g: 0.0, b: 0.0, a: 1.0 },
                    opacity: 1.0,
                }),
                stroke: None,
                common: CommonProps::default(),
                fill_gradient: None,
                stroke_gradient: None,
            }))],
            isolated_blending: false,
            knockout_group: false,
            common: CommonProps {
                visibility: Visibility::Invisible,
                ..Default::default()
            },
        }));
        let bytes = document_to_pdf(&doc);
        let s = String::from_utf8_lossy(&bytes);
        assert!(
            !s.contains("1 0 0 rg"),
            "invisible layer leaked into PDF:\n{}",
            s
        );

        doc.print_preferences.print_layers = PrintLayers::All;
        let bytes2 = document_to_pdf(&doc);
        let s2 = String::from_utf8_lossy(&bytes2);
        assert!(
            s2.contains("1 0 0 rg"),
            "All filter should include red rect"
        );
    }

    #[test]
    fn pdf_quad_to_cubic_endpoint_correct() {
        let p0 = (0.0, 0.0);
        let pc = (10.0, 10.0);
        let p1 = (20.0, 0.0);
        let (cp1, cp2) = quad_to_cubic_cps(p0, pc, p1);
        // cp1 = p0 + 2/3 * (pc - p0)
        let expected_cp1 = (
            p0.0 + 2.0 / 3.0 * (pc.0 - p0.0),
            p0.1 + 2.0 / 3.0 * (pc.1 - p0.1),
        );
        assert!((cp1.0 - expected_cp1.0).abs() < 1e-9);
        assert!((cp1.1 - expected_cp1.1).abs() < 1e-9);
        // cp2 = p1 + 2/3 * (pc - p1)
        let expected_cp2 = (
            p1.0 + 2.0 / 3.0 * (pc.0 - p1.0),
            p1.1 + 2.0 / 3.0 * (pc.1 - p1.1),
        );
        assert!((cp2.0 - expected_cp2.0).abs() < 1e-9);
        assert!((cp2.1 - expected_cp2.1).abs() < 1e-9);
    }
}
