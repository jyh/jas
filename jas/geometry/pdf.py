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
from document.print_preferences import PrintLayers, ScalingMode, OutputMode
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
    # Where the trim rect sits inside the (possibly bleed-extended)
    # MediaBox. (0, 0) when no bleed/marks are active.
    trim_x_off: float = 0.0
    trim_y_off: float = 0.0
    # PRINT.md §Phase 3: when set, this page is one channel of a
    # separations job. v1 renders the artwork the same way Composite
    # does and stamps the label as a small page-info string;
    # per-ink channel extraction is a deferred follow-up.
    separation_label: str | None = None


# Marks-and-Bleed PDF geometry constants (PRINT.md §Phase 2). Same
# values as Rust + Swift + OCaml so the cross-port output stays
# equivalent.
_TRIM_MARK_LENGTH = 12.0
_REG_MARK_RADIUS = 4.0
_COLOR_BAR_SWATCH = 10.0


def _active_bleed(doc: Document):
    """Effective bleed for a print pass: per-print overrides on
    marks_and_bleed when use_document_bleed is False, otherwise the
    document-level DocumentSetup bleed."""
    m = doc.print_preferences.marks_and_bleed
    if m.use_document_bleed:
        d = doc.document_setup
        return (d.bleed_top, d.bleed_right, d.bleed_bottom, d.bleed_left)
    return (m.bleed_top, m.bleed_right, m.bleed_bottom, m.bleed_left)


def _mark_gutter(m) -> float:
    """Extra space between the trim rect and the MediaBox edge needed
    to hold the marks. Zero when no mark category is enabled."""
    any_ = (m.all_printer_marks or m.trim_marks or m.registration_marks
            or m.color_bars or m.page_information)
    return m.mark_offset + _TRIM_MARK_LENGTH + 2.0 if any_ else 0.0


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
    bt, br, bb, bl = _active_bleed(doc)
    g = _mark_gutter(doc.print_preferences.marks_and_bleed)
    trim_x_off = bl + g
    trim_y_off = bb + g
    extra_w = bl + br + 2.0 * g
    extra_h = bt + bb + 2.0 * g
    if doc.print_preferences.ignore_artboards or not doc.artboards:
        if not doc.artboards:
            x, y, w, h = 0.0, 0.0, 612.0, 792.0
        else:
            x, y, w, h = _artboard_bounds_union(doc.artboards)
        base = [_Page(
            media_w=w + extra_w, media_h=h + extra_h,
            src_x=x, src_y=y, src_w=w, src_h=h,
            trim_x_off=trim_x_off, trim_y_off=trim_y_off)]
    else:
        base = [
            _Page(
                media_w=ab.width + extra_w, media_h=ab.height + extra_h,
                src_x=ab.x, src_y=ab.y, src_w=ab.width, src_h=ab.height,
                trim_x_off=trim_x_off, trim_y_off=trim_y_off)
            for ab in doc.artboards
        ]
    return _expand_for_separations(doc, base)


def _expand_for_separations(doc: Document, base: list[_Page]) -> list[_Page]:
    """In Composite mode, returns base unchanged. In Separations mode
    (PRINT.md §Phase 3), expands each base page into one copy per
    enabled ink in artboard-major order. When Separations is chosen
    but no inks are enabled, falls through to the composite pages so
    the user still gets a PDF instead of an empty file."""
    out = doc.print_preferences.output
    if out.mode != OutputMode.SEPARATIONS:
        return base
    enabled = [i for i in out.inks if i.print]
    if not enabled:
        return base
    expanded: list[_Page] = []
    for page in base:
        for ink in enabled:
            expanded.append(_Page(
                media_w=page.media_w, media_h=page.media_h,
                src_x=page.src_x, src_y=page.src_y,
                src_w=page.src_w, src_h=page.src_h,
                trim_x_off=page.trim_x_off, trim_y_off=page.trim_y_off,
                separation_label=ink.name))
    return expanded


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


def _emit_trim_marks(canvas: RLCanvas, tx, ty, tw, th, weight, off):
    canvas.saveState()
    canvas.setStrokeColorRGB(0.0, 0.0, 0.0, alpha=1.0)
    canvas.setLineWidth(weight)
    length = _TRIM_MARK_LENGTH
    # Eight short strokes, two per corner. PDF is y-up.
    segs = [
        (tx - off - length, ty,             tx - off,            ty),
        (tx,                ty - off - length, tx,               ty - off),
        (tx + tw + off,     ty,             tx + tw + off + length, ty),
        (tx + tw,           ty - off - length, tx + tw,          ty - off),
        (tx - off - length, ty + th,        tx - off,            ty + th),
        (tx,                ty + th + off,  tx,                  ty + th + off + length),
        (tx + tw + off,     ty + th,        tx + tw + off + length, ty + th),
        (tx + tw,           ty + th + off,  tx + tw,             ty + th + off + length),
    ]
    for x1, y1, x2, y2 in segs:
        canvas.line(x1, y1, x2, y2)
    canvas.restoreState()


def _emit_reg_mark(canvas: RLCanvas, cx, cy, r):
    canvas.saveState()
    canvas.setStrokeColorRGB(0.0, 0.0, 0.0, alpha=1.0)
    canvas.setLineWidth(0.25)
    canvas.circle(cx, cy, r, stroke=1, fill=0)
    canvas.line(cx - r, cy, cx + r, cy)
    canvas.line(cx, cy - r, cx, cy + r)
    canvas.restoreState()


def _emit_registration_marks(canvas: RLCanvas, tx, ty, tw, th, off):
    r = _REG_MARK_RADIUS
    centers = [
        (tx + tw / 2, ty - off - r),       # bottom mid (PDF y-up)
        (tx + tw + off + r, ty + th / 2),  # right mid
        (tx + tw / 2, ty + th + off + r),  # top mid
        (tx - off - r, ty + th / 2),       # left mid
    ]
    for cx, cy in centers:
        _emit_reg_mark(canvas, cx, cy, r)


def _emit_color_bars(canvas: RLCanvas, tx, ty, tw, th, _off):
    s = _COLOR_BAR_SWATCH
    swatches = [
        (0.0, 1.0, 1.0),    # C
        (1.0, 0.0, 1.0),    # M
        (1.0, 1.0, 0.0),    # Y
        (0.0, 0.0, 0.0),    # K
        (1.0, 0.0, 0.0),    # R
        (0.0, 1.0, 0.0),    # G
        (0.0, 0.0, 1.0),    # B
        (0.5, 0.5, 0.5),    # grey
    ]
    base_x = tx
    # Above the top trim edge (PDF is y-up).
    base_y = ty + th + _TRIM_MARK_LENGTH + 2.0
    for i, (r, g, b) in enumerate(swatches):
        x = base_x + i * s
        if x + s > tx + tw:
            break
        canvas.saveState()
        canvas.setFillColorRGB(r, g, b, alpha=1.0)
        canvas.rect(x, base_y, s, s, stroke=0, fill=1)
        canvas.restoreState()


def _emit_page_info(canvas: RLCanvas, tx, ty):
    # Phase-2 placeholder: a small label below the bottom trim edge
    # (PDF is y-up). Renderer-specific font metric work is deferred.
    canvas.saveState()
    canvas.setFillColorRGB(0.0, 0.0, 0.0, alpha=1.0)
    canvas.setFont("Helvetica", 6)
    canvas.drawString(tx, ty - _TRIM_MARK_LENGTH - 8, "Jas — page")
    canvas.restoreState()


def _emit_marks(canvas: RLCanvas, doc: Document, page: _Page):
    m = doc.print_preferences.marks_and_bleed
    if not (m.all_printer_marks or m.trim_marks or m.registration_marks
            or m.color_bars or m.page_information):
        return
    tx, ty = page.trim_x_off, page.trim_y_off
    tw, th = page.src_w, page.src_h
    if m.all_printer_marks or m.trim_marks:
        _emit_trim_marks(canvas, tx, ty, tw, th,
                         m.trim_mark_weight, m.mark_offset)
    if m.all_printer_marks or m.registration_marks:
        _emit_registration_marks(canvas, tx, ty, tw, th, m.mark_offset)
    if m.all_printer_marks or m.color_bars:
        _emit_color_bars(canvas, tx, ty, tw, th, m.mark_offset)
    if m.all_printer_marks or m.page_information:
        _emit_page_info(canvas, tx, ty)


def _draw_page(canvas: RLCanvas, doc: Document, page: _Page):
    canvas.saveState()
    sx, sy = _scaling_pair(doc)
    px = doc.print_preferences.placement_x
    py = doc.print_preferences.placement_y
    # Position the trim rect inside the (possibly bleed-extended)
    # MediaBox. PDF is y-up, internal model is y-down. Flip Y here,
    # then translate so document-space (page.src_x, page.src_y) lands
    # at the trim origin.
    if page.trim_x_off != 0 or page.trim_y_off != 0:
        canvas.translate(page.trim_x_off, page.trim_y_off)
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
    # Marks render in MediaBox space (no user transforms), aligned to
    # the trim rect inside it.
    _emit_marks(canvas, doc, page)
    # Separations label (PRINT.md §Phase 3): stamp the ink name on
    # each separations page so the printer / user can tell channels
    # apart. Placed at the bottom-right of the trim rect to avoid
    # colliding with the page-info string at the bottom-left.
    if page.separation_label is not None:
        _emit_separation_label(canvas, page, page.separation_label)


def _emit_separation_label(canvas: RLCanvas, page: _Page, name: str):
    label_x = page.trim_x_off + page.src_w - 80
    label_y = page.trim_y_off - 14
    canvas.saveState()
    canvas.setFillColorRGB(0, 0, 0, alpha=1)
    canvas.setFont("Helvetica", 6)
    canvas.drawString(label_x, label_y, name)
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
