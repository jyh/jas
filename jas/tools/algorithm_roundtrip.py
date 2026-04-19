#!/usr/bin/env python3
"""CLI tool for cross-language algorithm testing.

Usage:
    algorithm_roundtrip.py <algorithm> <fixture.json>
"""

import json
import math
import os
import sys

sys.path.insert(0, os.path.join(os.path.dirname(__file__), ".."))

from algorithms.hit_test import (
    point_in_rect, segments_intersect, segment_intersects_rect,
    rects_intersect, circle_intersects_rect, ellipse_intersects_rect,
    point_in_polygon,
)
from algorithms.boolean import (
    boolean_union, boolean_intersect, boolean_subtract, boolean_exclude,
)
from algorithms.boolean_normalize import normalize
from algorithms.fit_curve import fit_curve
from algorithms.shape_recognize import (
    recognize, RecognizeConfig,
    RecognizedLine, RecognizedTriangle, RecognizedRectangle,
    RecognizedRoundRect, RecognizedCircle, RecognizedEllipse,
    RecognizedArrow, RecognizedLemniscate, RecognizedScribble,
)
from algorithms.planar import build as planar_build
from algorithms.text_layout import (
    layout as text_layout, layout_with_paragraphs,
    ParagraphSegment, TextAlign,
)
from algorithms.path_text_layout import layout_path_text
from geometry.element import MoveTo, LineTo, CurveTo, QuadTo, ClosePath
from geometry.measure import Measure, Unit
from geometry.test_json import parse_element_json


def main():
    if len(sys.argv) < 3:
        print(f"Usage: {sys.argv[0]} <algorithm> <fixture.json>", file=sys.stderr)
        sys.exit(1)

    algo = sys.argv[1]
    path = sys.argv[2]

    with open(path) as f:
        fixture = json.load(f)

    if isinstance(fixture, list):
        vectors = fixture
    else:
        vectors = fixture["vectors"]

    # Filter skipped vectors
    vectors = [v for v in vectors if not v.get("_skip", False)]

    runners = {
        "measure": run_measure,
        "element_bounds": run_element_bounds,
        "hit_test": run_hit_test,
        "boolean": run_boolean,
        "boolean_normalize": run_boolean_normalize,
        "fit_curve": run_fit_curve,
        "shape_recognize": run_shape_recognize,
        "planar": run_planar,
        "text_layout": run_text_layout,
        "text_layout_paragraph": run_text_layout_paragraph,
        "path_text_layout": run_path_text_layout,
    }

    if algo not in runners:
        print(f"Unknown algorithm: {algo}", file=sys.stderr)
        sys.exit(1)

    results = runners[algo](vectors)
    print(json.dumps(results, sort_keys=True), end="")


# ---------------------------------------------------------------
# Measure (unit conversion)
# ---------------------------------------------------------------

_UNIT_MAP = {
    "px": Unit.PX, "pt": Unit.PT, "pc": Unit.PC, "in": Unit.IN,
    "cm": Unit.CM, "mm": Unit.MM, "em": Unit.EM, "rem": Unit.REM,
}

def run_measure(vectors):
    results = []
    for tc in vectors:
        unit = _UNIT_MAP[tc["unit"]]
        m = Measure(tc["value"], unit)
        font_size = tc.get("font_size", 16.0)
        results.append({"name": tc["name"], "result": m.to_px(font_size)})
    return results


# ---------------------------------------------------------------
# Element bounds
# ---------------------------------------------------------------

def run_element_bounds(vectors):
    results = []
    for tc in vectors:
        elem = parse_element_json(tc["element"])
        x, y, w, h = elem.bounds()
        results.append({"name": tc["name"], "result": [x, y, w, h]})
    return results


# ---------------------------------------------------------------
# Hit test
# ---------------------------------------------------------------

def run_hit_test(vectors):
    results = []
    for tc in vectors:
        name = tc["name"]
        fn = tc["function"]
        a = tc["args"]
        if fn == "point_in_rect":
            r = point_in_rect(a[0], a[1], a[2], a[3], a[4], a[5])
        elif fn == "segments_intersect":
            r = segments_intersect(a[0], a[1], a[2], a[3], a[4], a[5], a[6], a[7])
        elif fn == "segment_intersects_rect":
            r = segment_intersects_rect(a[0], a[1], a[2], a[3], a[4], a[5], a[6], a[7])
        elif fn == "rects_intersect":
            r = rects_intersect(a[0], a[1], a[2], a[3], a[4], a[5], a[6], a[7])
        elif fn == "circle_intersects_rect":
            filled = tc.get("filled", True)
            r = circle_intersects_rect(a[0], a[1], a[2], a[3], a[4], a[5], a[6], filled)
        elif fn == "ellipse_intersects_rect":
            filled = tc.get("filled", True)
            r = ellipse_intersects_rect(a[0], a[1], a[2], a[3], a[4], a[5], a[6], a[7], filled)
        elif fn == "point_in_polygon":
            poly = [tuple(p) for p in tc["polygon"]]
            r = point_in_polygon(a[0], a[1], poly)
        else:
            print(f"Unknown hit_test function: {fn}", file=sys.stderr)
            sys.exit(1)
        results.append({"name": name, "result": r})
    return results


# ---------------------------------------------------------------
# Boolean
# ---------------------------------------------------------------

def parse_polygon_set(v):
    return [[(p[0], p[1]) for p in ring] for ring in v]


def run_boolean(vectors):
    results = []
    for tc in vectors:
        name = tc["name"]
        fn = tc["function"]
        a = parse_polygon_set(tc["a"])
        b = parse_polygon_set(tc["b"])
        ops = {"union": boolean_union, "intersect": boolean_intersect,
               "subtract": boolean_subtract, "exclude": boolean_exclude}
        res = ops[fn](a, b)
        sample_pts = tc["expected"].get("sample_points", [])
        samples = []
        for sp in sample_pts:
            pt = (sp["point"][0], sp["point"][1])
            inside = point_in_polygon_set(res, pt)
            samples.append({"point": [pt[0], pt[1]], "inside": inside})
        results.append({"name": name, "result": {
            "area": polygon_set_area(res),
            "ring_count": len(res),
            "sample_points": samples,
        }})
    return results


# ---------------------------------------------------------------
# Boolean Normalize
# ---------------------------------------------------------------

def run_boolean_normalize(vectors):
    results = []
    for tc in vectors:
        name = tc["name"]
        inp = parse_polygon_set(tc["input"])
        res = normalize(inp)
        results.append({"name": name, "result": {
            "area": polygon_set_area(res),
            "ring_count": len(res),
            "all_rings_simple": all_rings_simple(res),
        }})
    return results


# ---------------------------------------------------------------
# Fit Curve
# ---------------------------------------------------------------

def run_fit_curve(vectors):
    results = []
    for tc in vectors:
        name = tc["name"]
        points = [(p[0], p[1]) for p in tc["points"]]
        error = tc["error"]
        segs = fit_curve(points, error)
        seg_json = [list(s) for s in segs]
        results.append({"name": name, "result": {
            "segment_count": len(segs),
            "segments": seg_json,
        }})
    return results


# ---------------------------------------------------------------
# Shape Recognize
# ---------------------------------------------------------------

def run_shape_recognize(vectors):
    results = []
    for tc in vectors:
        name = tc["name"]
        points = [(p[0], p[1]) for p in tc["points"]]
        cfg = RecognizeConfig()
        if "config" in tc and tc["config"]:
            cfg = RecognizeConfig(tolerance=tc["config"].get("tolerance", cfg.tolerance))
        shape = recognize(points, cfg)
        results.append({"name": name, "result": shape_to_dict(shape)})
    return results


def shape_to_dict(shape):
    if shape is None:
        return None
    if isinstance(shape, RecognizedLine):
        return {"kind": "line", "params": {
            "ax": shape.a[0], "ay": shape.a[1],
            "bx": shape.b[0], "by": shape.b[1]}}
    if isinstance(shape, RecognizedTriangle):
        return {"kind": "triangle", "params": {
            "pts": [[p[0], p[1]] for p in shape.pts]}}
    if isinstance(shape, RecognizedRectangle):
        kind = "square" if abs(shape.w - shape.h) < 1e-9 else "rectangle"
        return {"kind": kind, "params": {
            "x": shape.x, "y": shape.y, "w": shape.w, "h": shape.h}}
    if isinstance(shape, RecognizedRoundRect):
        return {"kind": "round_rect", "params": {
            "x": shape.x, "y": shape.y, "w": shape.w, "h": shape.h, "r": shape.r}}
    if isinstance(shape, RecognizedCircle):
        return {"kind": "circle", "params": {
            "cx": shape.cx, "cy": shape.cy, "r": shape.r}}
    if isinstance(shape, RecognizedEllipse):
        return {"kind": "ellipse", "params": {
            "cx": shape.cx, "cy": shape.cy, "rx": shape.rx, "ry": shape.ry}}
    if isinstance(shape, RecognizedArrow):
        return {"kind": "arrow", "params": {
            "tail_x": shape.tail[0], "tail_y": shape.tail[1],
            "tip_x": shape.tip[0], "tip_y": shape.tip[1],
            "head_len": shape.head_len, "head_half_width": shape.head_half_width,
            "shaft_half_width": shape.shaft_half_width}}
    if isinstance(shape, RecognizedLemniscate):
        return {"kind": "lemniscate", "params": {
            "cx": shape.center[0], "cy": shape.center[1],
            "a": shape.a, "horizontal": shape.horizontal}}
    if isinstance(shape, RecognizedScribble):
        return {"kind": "scribble", "params": {
            "points": [[p[0], p[1]] for p in shape.points]}}
    return None


# ---------------------------------------------------------------
# Planar
# ---------------------------------------------------------------

def run_planar(vectors):
    results = []
    for tc in vectors:
        name = tc["name"]
        polylines = [[(p[0], p[1]) for p in pl] for pl in tc["polylines"]]
        graph = planar_build(polylines)
        fc = graph.face_count()
        areas = sorted(graph.face_net_area(i) for i in range(fc))
        sample_pts = tc["expected"].get("sample_points", [])
        samples = []
        for sp in sample_pts:
            pt = (sp["point"][0], sp["point"][1])
            hit = graph.hit_test(pt)
            samples.append({"point": [pt[0], pt[1]], "inside_any_face": hit is not None})
        results.append({"name": name, "result": {
            "face_count": fc,
            "face_areas_sorted": areas,
            "sample_points": samples,
        }})
    return results


# ---------------------------------------------------------------
# Text Layout
# ---------------------------------------------------------------

def run_text_layout(vectors):
    results = []
    for tc in vectors:
        name = tc["name"]
        content = tc["content"]
        max_width = tc["max_width"]
        font_size = tc["font_size"]
        char_width = tc["char_width"]
        measure = lambda s, cw=char_width: len(s) * cw
        lay = text_layout(content, max_width, font_size, measure)
        glyphs = [{"idx": g.idx, "line": g.line, "right": g.right, "x": g.x}
                  for g in lay.glyphs]
        results.append({"name": name, "result": {
            "char_count": lay.char_count,
            "glyphs": glyphs,
            "line_count": len(lay.lines),
        }})
    return results


# ---------------------------------------------------------------
# Text Layout Paragraph (Phase 11 parity)
# ---------------------------------------------------------------


_ALIGN_MAP = {
    "center": TextAlign.CENTER,
    "right": TextAlign.RIGHT,
    "justify": TextAlign.JUSTIFY,
}


def _parse_align(value):
    return _ALIGN_MAP.get(value, TextAlign.LEFT)


def _parse_seg(d):
    dflt = ParagraphSegment()
    return ParagraphSegment(
        char_start=int(d.get("char_start", 0)),
        char_end=int(d.get("char_end", 0)),
        left_indent=float(d.get("left_indent", dflt.left_indent)),
        right_indent=float(d.get("right_indent", dflt.right_indent)),
        first_line_indent=float(d.get("first_line_indent", dflt.first_line_indent)),
        space_before=float(d.get("space_before", dflt.space_before)),
        space_after=float(d.get("space_after", dflt.space_after)),
        text_align=_parse_align(d.get("text_align")),
        list_style=d.get("list_style"),
        marker_gap=float(d.get("marker_gap", dflt.marker_gap)),
        hanging_punctuation=bool(d.get("hanging_punctuation", False)),
        word_spacing_min=float(d.get("word_spacing_min", dflt.word_spacing_min)),
        word_spacing_desired=float(d.get("word_spacing_desired", dflt.word_spacing_desired)),
        word_spacing_max=float(d.get("word_spacing_max", dflt.word_spacing_max)),
        last_line_align=_parse_align(d.get("last_line_align")),
        hyphenate=bool(d.get("hyphenate", False)),
        hyphenate_min_word=int(d.get("hyphenate_min_word", dflt.hyphenate_min_word)),
        hyphenate_min_before=int(d.get("hyphenate_min_before", dflt.hyphenate_min_before)),
        hyphenate_min_after=int(d.get("hyphenate_min_after", dflt.hyphenate_min_after)),
        hyphenate_bias=int(d.get("hyphenate_bias", dflt.hyphenate_bias)),
    )


def run_text_layout_paragraph(vectors):
    results = []
    for tc in vectors:
        name = tc["name"]
        content = tc["content"]
        max_width = tc["max_width"]
        font_size = tc["font_size"]
        char_width = tc["char_width"]
        segs = [_parse_seg(s) for s in tc.get("paragraphs", [])]
        measure = lambda s, cw=char_width: len(s) * cw
        lay = layout_with_paragraphs(content, max_width, font_size, segs, measure)
        glyphs = [{"idx": g.idx, "line": g.line, "right": g.right, "x": g.x}
                  for g in lay.glyphs]
        results.append({"name": name, "result": {
            "char_count": lay.char_count,
            "glyphs": glyphs,
            "line_count": len(lay.lines),
        }})
    return results


# ---------------------------------------------------------------
# Path Text Layout
# ---------------------------------------------------------------

def parse_path_commands(v):
    cmds = []
    for c in v:
        cmd = c["cmd"]
        if cmd == "M":
            cmds.append(MoveTo(c["x"], c["y"]))
        elif cmd == "L":
            cmds.append(LineTo(c["x"], c["y"]))
        elif cmd == "C":
            cmds.append(CurveTo(c["x1"], c["y1"], c["x2"], c["y2"], c["x"], c["y"]))
        elif cmd == "Q":
            cmds.append(QuadTo(c["x1"], c["y1"], c["x"], c["y"]))
        elif cmd == "Z":
            cmds.append(ClosePath())
        else:
            print(f"Unknown path command: {cmd}", file=sys.stderr)
            sys.exit(1)
    return tuple(cmds)


def run_path_text_layout(vectors):
    results = []
    for tc in vectors:
        name = tc["name"]
        path_cmds = parse_path_commands(tc["path"])
        content = tc["content"]
        start_offset = tc["start_offset"]
        font_size = tc["font_size"]
        char_width = tc["char_width"]
        measure = lambda s, cw=char_width: len(s) * cw
        lay = layout_path_text(path_cmds, content, start_offset, font_size, measure)
        glyphs = [{"angle": g.angle, "cx": g.cx, "cy": g.cy,
                    "idx": g.idx, "overflow": g.overflow}
                  for g in lay.glyphs]
        results.append({"name": name, "result": {
            "char_count": lay.char_count,
            "glyphs": glyphs,
            "total_length": lay.total_length,
        }})
    return results


# ---------------------------------------------------------------
# Geometry helpers
# ---------------------------------------------------------------

def ring_signed_area(ring):
    n = len(ring)
    if n < 3:
        return 0.0
    s = 0.0
    for i in range(n):
        x1, y1 = ring[i]
        x2, y2 = ring[(i + 1) % n]
        s += x1 * y2 - x2 * y1
    return s * 0.5


def point_in_ring(ring, pt):
    px, py = pt
    n = len(ring)
    if n < 3:
        return False
    inside = False
    j = n - 1
    for i in range(n):
        xi, yi = ring[i]
        xj, yj = ring[j]
        if ((yi > py) != (yj > py)) and (px < (xj - xi) * (py - yi) / (yj - yi) + xi):
            inside = not inside
        j = i
    return inside


def point_in_polygon_set(ps, pt):
    count = sum(1 for ring in ps if point_in_ring(ring, pt))
    return count % 2 == 1


def polygon_set_area(ps):
    total = 0.0
    for i, ring in enumerate(ps):
        a = abs(ring_signed_area(ring))
        depth = 0
        if ring:
            pt = ring[0]
            for j, other in enumerate(ps):
                if i != j and point_in_ring(other, pt):
                    depth += 1
        total += a if depth % 2 == 0 else -a
    return total


def proper_crossing(ax1, ay1, ax2, ay2, bx1, by1, bx2, by2):
    def cross(ux, uy, vx, vy):
        return ux * vy - uy * vx
    d1 = cross(bx2 - bx1, by2 - by1, ax1 - bx1, ay1 - by1)
    d2 = cross(bx2 - bx1, by2 - by1, ax2 - bx1, ay2 - by1)
    d3 = cross(ax2 - ax1, ay2 - ay1, bx1 - ax1, by1 - ay1)
    d4 = cross(ax2 - ax1, ay2 - ay1, bx2 - ax1, by2 - ay1)
    return d1 * d2 < 0 and d3 * d4 < 0


def is_ring_simple(ring):
    n = len(ring)
    if n < 3:
        return True
    for i in range(n):
        ax1, ay1 = ring[i]
        ax2, ay2 = ring[(i + 1) % n]
        for j in range(i + 2, n):
            if i == 0 and j == n - 1:
                continue
            bx1, by1 = ring[j]
            bx2, by2 = ring[(j + 1) % n]
            if proper_crossing(ax1, ay1, ax2, ay2, bx1, by1, bx2, by2):
                return False
    return True


def all_rings_simple(ps):
    return all(is_ring_simple(ring) for ring in ps)


if __name__ == "__main__":
    main()
