"""PDF emitter (PRINT.md §Phase 1B). Uses ReportLab's canvas API.

Walks the document, emitting one page per artboard (or a single page
covering the artboard union when print_preferences.ignore_artboards
is set). Element coverage matches Rust + Swift + OCaml: path (cubic +
smooth + quad-as-cubic + arc-as-line fallback), rect, line, circle,
ellipse, polyline, polygon, basic single-tspan text via Helvetica,
groups, layers. PrintLayers filter applied at layer boundaries;
VISIBLE_PRINTABLE currently collapses to VISIBLE until a future
Layer.print flag lands."""

from __future__ import annotations

import io
import math
from dataclasses import dataclass

from document.document import Document
from document.print_preferences import PrintLayers, ScalingMode
from geometry.element import (
    Circle, Color, Ellipse, Group, Layer, Line, Path, Polygon, Polyline, Rect,
    Text, TextPath, Visibility,
)
from reportlab.lib.colors import Color as RLColor
from reportlab.pdfgen.canvas import Canvas as RLCanvas


@dataclass
class _Page:
    media_w: float
    media_h: float
    src_x: float
    src_y: float
    src_w: float
    src_h: float


def _artboard_bounds_union(abs_):
    min_x, min_y = math.inf, math.inf
    max_x, max_y = -math.inf, -math.inf
    for ab in abs_:
        min_x = min(min_x, ab.x)
        min_y = min(min_y, ab.y)
        max_x = max(max_x, ab.x + ab.width)
        max_y = max(max_y, ab.y + ab.height)
    return (min_x, min_y, max_x - min_x, max_y - min_y)


def _collect_pages(doc: Document) -> list[_Page]:
    if doc.print_preferences.ignore_artboards or not doc.artboards:
        if not doc.artboards:
            x, y, w, h = 0.0, 0.0, 612.0, 792.0
        else:
            x, y, w, h = _artboard_bounds_union(doc.artboards)
        return [_Page(media_w=w, media_h=h, src_x=x, src_y=y, src_w=w, src_h=h)]
    return [
        _Page(media_w=ab.width, media_h=ab.height,
              src_x=ab.x, src_y=ab.y, src_w=ab.width, src_h=ab.height)
        for ab in doc.artboards
    ]


def _scaling_pair(doc: Document) -> tuple[float, float]:
    sm = doc.print_preferences.scaling_mode
    if sm in (ScalingMode.DO_NOT_SCALE, ScalingMode.FIT_TO_PAGE):
        return (1.0, 1.0)
    s = doc.print_preferences.custom_scale / 100.0
    return (s, s)


def _layer_passes_filter(layer: Layer, filt: PrintLayers) -> bool:
    if filt == PrintLayers.ALL:
        return True
    # VISIBLE_PRINTABLE collapses to VISIBLE until Layer.print lands.
    return layer.visibility != Visibility.INVISIBLE


def _color_rgb(c: Color) -> RLColor:
    if hasattr(c, "r") and hasattr(c, "g") and hasattr(c, "b"):
        return RLColor(c.r, c.g, c.b, alpha=c.a)
    # HSB / CMYK fallback to black.
    return RLColor(0.0, 0.0, 0.0, alpha=1.0)


def _apply_transform(canvas: RLCanvas, t):
    if t is None:
        return
    canvas.transform(t.a, t.b, t.c, t.d, t.e, t.f)


def _quad_to_cubic_cps(p0, pc, p1):
    p0x, p0y = p0; pcx, pcy = pc; p1x, p1y = p1
    cp1 = (p0x + 2.0 / 3.0 * (pcx - p0x), p0y + 2.0 / 3.0 * (pcy - p0y))
    cp2 = (p1x + 2.0 / 3.0 * (pcx - p1x), p1y + 2.0 / 3.0 * (pcy - p1y))
    return cp1, cp2


def _add_path_commands(p, commands):
    """Push path-command list into a ReportLab PDFPathObject `p`."""
    cur = (0.0, 0.0)
    prev_cubic_cp = None
    prev_quad_cp = None
    for cmd in commands:
        kind = cmd[0]
        if kind == "M":
            _, x, y = cmd
            p.moveTo(x, y)
            cur = (x, y); prev_cubic_cp = None; prev_quad_cp = None
        elif kind == "L":
            _, x, y = cmd
            p.lineTo(x, y)
            cur = (x, y); prev_cubic_cp = None; prev_quad_cp = None
        elif kind == "C":
            _, x1, y1, x2, y2, x, y = cmd
            p.curveTo(x1, y1, x2, y2, x, y)
            cur = (x, y); prev_cubic_cp = (x2, y2); prev_quad_cp = None
        elif kind == "S":
            _, x2, y2, x, y = cmd
            cx, cy = cur
            if prev_cubic_cp is not None:
                px, py = prev_cubic_cp
                x1, y1 = (2 * cx - px, 2 * cy - py)
            else:
                x1, y1 = (cx, cy)
            p.curveTo(x1, y1, x2, y2, x, y)
            cur = (x, y); prev_cubic_cp = (x2, y2); prev_quad_cp = None
        elif kind == "Q":
            _, x1, y1, x, y = cmd
            cp1, cp2 = _quad_to_cubic_cps(cur, (x1, y1), (x, y))
            p.curveTo(cp1[0], cp1[1], cp2[0], cp2[1], x, y)
            cur = (x, y); prev_cubic_cp = None; prev_quad_cp = (x1, y1)
        elif kind == "T":
            _, x, y = cmd
            cx, cy = cur
            if prev_quad_cp is not None:
                px, py = prev_quad_cp
                q_ctrl = (2 * cx - px, 2 * cy - py)
            else:
                q_ctrl = (cx, cy)
            cp1, cp2 = _quad_to_cubic_cps(cur, q_ctrl, (x, y))
            p.curveTo(cp1[0], cp1[1], cp2[0], cp2[1], x, y)
            cur = (x, y); prev_cubic_cp = None; prev_quad_cp = q_ctrl
        elif kind == "A":
            # Phase 1B deferral: arc-as-line fallback.
            x, y = cmd[-2], cmd[-1]
            p.lineTo(x, y)
            cur = (x, y); prev_cubic_cp = None; prev_quad_cp = None
        elif kind == "Z":
            p.close()
            prev_cubic_cp = None; prev_quad_cp = None


def _set_paint(canvas: RLCanvas, fill, stroke):
    if fill is not None:
        c = _color_rgb(fill.color)
        # Fill alpha = color.a * fill_opacity
        a = c.alpha * fill.opacity
        canvas.setFillColorRGB(c.red, c.green, c.blue, alpha=a)
    if stroke is not None:
        c = _color_rgb(stroke.color)
        a = c.alpha * stroke.opacity
        canvas.setStrokeColorRGB(c.red, c.green, c.blue, alpha=a)
        canvas.setLineWidth(stroke.width)


def _emit_paint_path(canvas: RLCanvas, fill, stroke, transform, add_geom):
    if fill is None and stroke is None:
        return
    canvas.saveState()
    _apply_transform(canvas, transform)
    p = canvas.beginPath()
    add_geom(p)
    _set_paint(canvas, fill, stroke)
    canvas.drawPath(p, stroke=int(stroke is not None), fill=int(fill is not None))
    canvas.restoreState()


def _emit_element(canvas: RLCanvas, el, filt: PrintLayers):
    if isinstance(el, Layer):
        if not _layer_passes_filter(el, filt):
            return
        canvas.saveState()
        _apply_transform(canvas, el.transform)
        for child in el.children:
            _emit_element(canvas, child, filt)
        canvas.restoreState()
        return
    if isinstance(el, Group):
        if el.visibility == Visibility.INVISIBLE:
            return
        canvas.saveState()
        _apply_transform(canvas, el.transform)
        for child in el.children:
            _emit_element(canvas, child, filt)
        canvas.restoreState()
        return
    vis = getattr(el, "visibility", Visibility.PREVIEW)
    if vis == Visibility.INVISIBLE:
        return
    if isinstance(el, Rect):
        def add(p):
            p.rect(el.x, el.y, el.width, el.height)
        _emit_paint_path(canvas, el.fill, el.stroke, el.transform, add)
    elif isinstance(el, Line):
        # Lines have no fill; stroke only.
        if el.stroke is None:
            return
        canvas.saveState()
        _apply_transform(canvas, el.transform)
        _set_paint(canvas, None, el.stroke)
        canvas.line(el.x1, el.y1, el.x2, el.y2)
        canvas.restoreState()
    elif isinstance(el, Circle):
        def add(p):
            # ReportLab's PDFPathObject lacks a circle helper, but
            # we can use four cubic-Bezier quadrants ourselves. Easier:
            # use canvas.circle when there's no stroke/fill custom path.
            # For uniform-paint case we just draw via canvas.circle.
            pass
        canvas.saveState()
        _apply_transform(canvas, el.transform)
        _set_paint(canvas, el.fill, el.stroke)
        canvas.circle(el.cx, el.cy, el.r,
                      stroke=int(el.stroke is not None),
                      fill=int(el.fill is not None))
        canvas.restoreState()
    elif isinstance(el, Ellipse):
        canvas.saveState()
        _apply_transform(canvas, el.transform)
        _set_paint(canvas, el.fill, el.stroke)
        canvas.ellipse(el.cx - el.rx, el.cy - el.ry,
                       el.cx + el.rx, el.cy + el.ry,
                       stroke=int(el.stroke is not None),
                       fill=int(el.fill is not None))
        canvas.restoreState()
    elif isinstance(el, Polyline):
        def add(p):
            if not el.points:
                return
            x0, y0 = el.points[0]
            p.moveTo(x0, y0)
            for x, y in el.points[1:]:
                p.lineTo(x, y)
        _emit_paint_path(canvas, el.fill, el.stroke, el.transform, add)
    elif isinstance(el, Polygon):
        def add(p):
            if not el.points:
                return
            x0, y0 = el.points[0]
            p.moveTo(x0, y0)
            for x, y in el.points[1:]:
                p.lineTo(x, y)
            p.close()
        _emit_paint_path(canvas, el.fill, el.stroke, el.transform, add)
    elif isinstance(el, Path):
        def add(p):
            _add_path_commands(p, el.d)
        _emit_paint_path(canvas, el.fill, el.stroke, el.transform, add)
    elif isinstance(el, Text):
        s = "".join(t.content for t in el.tspans)
        if not s:
            return
        canvas.saveState()
        _apply_transform(canvas, el.transform)
        if el.fill is not None:
            c = _color_rgb(el.fill.color)
            canvas.setFillColorRGB(c.red, c.green, c.blue,
                                   alpha=c.alpha * el.fill.opacity)
        canvas.setFont("Helvetica", el.font_size)
        canvas.drawString(el.x, el.y, s)
        canvas.restoreState()
    elif isinstance(el, TextPath):
        # Phase 1B deferral.
        return


def _draw_page(canvas: RLCanvas, doc: Document, page: _Page):
    canvas.saveState()
    sx, sy = _scaling_pair(doc)
    px = doc.print_preferences.placement_x
    py = doc.print_preferences.placement_y
    # PDF is y-up, internal model is y-down. Flip Y here, then translate
    # so document-space (page.src_x, page.src_y) lands at the page origin.
    canvas.translate(0, page.src_h)
    canvas.scale(1, -1)
    if px != 0 or py != 0:
        canvas.translate(px, py)
    if sx != 1 or sy != 1:
        canvas.scale(sx, sy)
    if page.src_x != 0 or page.src_y != 0:
        canvas.translate(-page.src_x, -page.src_y)
    for layer in doc.layers:
        _emit_element(canvas, layer, doc.print_preferences.print_layers)
    canvas.restoreState()


def document_to_pdf(doc: Document) -> bytes:
    """Convert a document to PDF bytes."""
    pages = _collect_pages(doc)
    buf = io.BytesIO()
    first = pages[0] if pages else _Page(
        media_w=612.0, media_h=792.0, src_x=0.0, src_y=0.0,
        src_w=612.0, src_h=792.0)
    canvas = RLCanvas(buf, pagesize=(first.media_w, first.media_h))
    for i, page in enumerate(pages):
        if i > 0:
            canvas.setPageSize((page.media_w, page.media_h))
        _draw_page(canvas, doc, page)
        canvas.showPage()
    canvas.save()
    return buf.getvalue()
