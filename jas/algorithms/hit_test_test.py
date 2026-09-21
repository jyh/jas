"""Hit test primitives. Mirrors jas_dioxus/src/algorithms/hit_test.rs."""

from __future__ import annotations

from algorithms.hit_test import (
    point_in_rect,
    segments_intersect,
    segment_intersects_rect,
    rects_intersect,
    element_intersects_rect,
    element_intersects_polygon,
)
from geometry.element import RgbColor, Fill, Line, Rect, Stroke, Transform


# ---- point_in_rect ----


def test_point_in_rect_interior():
    assert point_in_rect(5, 5, 0, 0, 10, 10)


def test_point_in_rect_outside():
    assert not point_in_rect(15, 5, 0, 0, 10, 10)
    assert not point_in_rect(-1, 5, 0, 0, 10, 10)
    assert not point_in_rect(5, 15, 0, 0, 10, 10)
    assert not point_in_rect(5, -1, 0, 0, 10, 10)


def test_point_in_rect_on_edge():
    assert point_in_rect(0, 5, 0, 0, 10, 10)
    assert point_in_rect(10, 5, 0, 0, 10, 10)
    assert point_in_rect(5, 0, 0, 0, 10, 10)
    assert point_in_rect(5, 10, 0, 0, 10, 10)


def test_point_in_rect_on_corner():
    assert point_in_rect(0, 0, 0, 0, 10, 10)
    assert point_in_rect(10, 10, 0, 0, 10, 10)


# ---- segments_intersect ----


def test_segments_intersect_crossing():
    assert segments_intersect(0, 0, 10, 10, 0, 10, 10, 0)


def test_segments_intersect_parallel_no():
    assert not segments_intersect(0, 0, 10, 0, 0, 1, 10, 1)


def test_segments_intersect_separate():
    assert not segments_intersect(0, 0, 1, 1, 5, 5, 6, 6)


def test_segments_intersect_touching_at_endpoint():
    assert segments_intersect(0, 0, 5, 5, 5, 5, 10, 10)


def test_segments_intersect_t_intersection():
    assert segments_intersect(0, 5, 10, 5, 5, 5, 5, 0)


# ---- segment_intersects_rect ----


def test_segment_inside_rect():
    assert segment_intersects_rect(2, 2, 8, 8, 0, 0, 10, 10)


def test_segment_outside_rect():
    assert not segment_intersects_rect(20, 0, 30, 0, 0, 0, 10, 10)


def test_segment_crosses_rect():
    assert segment_intersects_rect(-5, 5, 15, 5, 0, 0, 10, 10)


def test_segment_one_endpoint_inside():
    assert segment_intersects_rect(5, 5, 20, 20, 0, 0, 10, 10)


def test_segment_endpoint_on_edge():
    assert segment_intersects_rect(10, 5, 20, 5, 0, 0, 10, 10)


# ---- rects_intersect ----


def test_rects_intersect_overlapping():
    assert rects_intersect(0, 0, 10, 10, 5, 5, 10, 10)


def test_rects_intersect_separate():
    assert not rects_intersect(0, 0, 10, 10, 20, 0, 10, 10)


def test_rects_intersect_contained():
    assert rects_intersect(0, 0, 100, 100, 25, 25, 50, 50)


def test_rects_intersect_edge_touching():
    assert not rects_intersect(0, 0, 10, 10, 10, 0, 10, 10)


def test_rects_intersect_corner_touching():
    assert not rects_intersect(0, 0, 10, 10, 10, 10, 10, 10)


def test_rects_intersect_identical():
    assert rects_intersect(0, 0, 10, 10, 0, 0, 10, 10)


# ---- element_intersects_rect ----


def _stroke():
    return Stroke(color=RgbColor(0, 0, 0), width=1.0)


def test_line_element_overlapping_rect():
    line = Line(x1=-5, y1=5, x2=15, y2=5, stroke=_stroke())
    assert element_intersects_rect(line, 0, 0, 10, 10)


def test_line_element_outside_rect():
    line = Line(x1=20, y1=0, x2=30, y2=0, stroke=_stroke())
    assert not element_intersects_rect(line, 0, 0, 10, 10)


def test_rect_element_overlapping_rect():
    rect = Rect(x=5, y=5, width=10, height=10, stroke=_stroke())
    assert element_intersects_rect(rect, 0, 0, 10, 10)


def test_rect_element_outside_rect():
    rect = Rect(x=20, y=20, width=5, height=5, stroke=_stroke())
    assert not element_intersects_rect(rect, 0, 0, 10, 10)


# ---- transform-aware hit-testing ----


def test_translated_line_intersects_rect():
    line = Line(x1=0, y1=5, x2=10, y2=5,
                transform=Transform.translate(100, 0))
    assert element_intersects_rect(line, 95, 0, 20, 10)
    assert not element_intersects_rect(line, 0, 0, 10, 10)


def test_rotated_rect_intersects_rect():
    rect = Rect(x=0, y=0, width=10, height=10,
                fill=Fill(color=RgbColor(r=0, g=0, b=0)),
                transform=Transform.rotate(45))
    assert element_intersects_rect(rect, 6, 6, 2, 2)
    assert not element_intersects_rect(rect, 12, 0, 2, 2)


def test_scaled_line_intersects_rect():
    line = Line(x1=0, y1=0, x2=5, y2=0,
                transform=Transform.scale(2, 2))
    assert element_intersects_rect(line, 8, -1, 4, 2)
    assert element_intersects_rect(line, 6, -1, 2, 2)


def test_singular_transform_returns_false():
    line = Line(x1=0, y1=0, x2=10, y2=0,
                transform=Transform.scale(0, 0))
    assert not element_intersects_rect(line, 0, 0, 10, 10)


def test_no_transform_still_works():
    line = Line(x1=0, y1=5, x2=10, y2=5)
    assert element_intersects_rect(line, 0, 0, 10, 10)
    assert not element_intersects_rect(line, 20, 0, 10, 10)


def test_translated_line_intersects_polygon():
    line = Line(x1=0, y1=5, x2=10, y2=5,
                transform=Transform.translate(100, 0))
    sq = [(95, 0), (115, 0), (115, 10), (95, 10)]
    assert element_intersects_polygon(line, sq)
    sq2 = [(0, 0), (10, 0), (10, 10), (0, 10)]
    assert not element_intersects_polygon(line, sq2)


# ---- the second dispatch path covers the first's kinds ----
#
# `element_intersects_rect` sends a transformed element to the POLYGON
# path (the inverse image of a marquee is a parallelogram), so every kind
# must answer alike on both paths. The corpus's control pairs
# (test_fixtures/algorithms/hit_test.json) pin that for the ports; these
# pin the arms the reference was missing, each against the answer the
# ports give (jas_dioxus/src/algorithms/hit_test.rs, JasSwift's
# HitTest.swift).

from geometry.element import (  # noqa: E402
    Circle, CompoundOperation, CompoundShape, Ellipse, LineTo, MoveTo,
    Path, Polygon, TextPath,
)


def _fill():
    return Fill(color=RgbColor(r=1, g=0, b=0))


def _box(x0, y0, x1, y1):
    return [(x0, y0), (x1, y0), (x1, y1), (x0, y1)]


def test_filled_ellipse_enclosed_by_lasso_hits():
    # The ellipse occupies [4,16]x[6,14]; the lasso contains it. No vertex
    # of the lasso is inside the ellipse and no segment crosses it, so only
    # a real ellipse test can see this.
    e = Ellipse(cx=10, cy=10, rx=6, ry=4, fill=_fill())
    assert element_intersects_polygon(e, _box(0, 0, 20, 20))


def test_unfilled_ellipse_lasso_hits_only_the_outline():
    e = Ellipse(cx=10, cy=10, rx=6, ry=4, stroke=_stroke())
    assert element_intersects_polygon(e, _box(14, 8, 18, 12))      # crosses (16,10)
    assert not element_intersects_polygon(e, _box(8, 9, 12, 11))   # inside the outline
    assert not element_intersects_polygon(e, _box(30, 30, 40, 40)) # far outside


def test_filled_ellipse_identity_marquee_in_bbox_corner_misses():
    # (4,6)-(5,7) is inside the bounding box and outside the paint:
    # ((4.5-10)/6)^2 + ((6.5-10)/4)^2 = 0.84 + 0.77 > 1 at its nearest
    # corner (5,7): 0.69 + 0.56 = 1.25 > 1.
    e = Ellipse(cx=10, cy=10, rx=6, ry=4, fill=_fill(),
                transform=Transform())
    assert not element_intersects_rect(e, 4, 6, 1, 1)
    assert element_intersects_rect(e, 0, 0, 20, 20)


def test_circle_answers_alike_on_both_paths():
    # The frozen app still builds `Circle`; its polygon path had no arm.
    c = Circle(cx=10, cy=10, r=5, fill=_fill())
    assert element_intersects_rect(c, 0, 0, 20, 20)
    assert element_intersects_polygon(c, _box(0, 0, 20, 20))
    ring = Circle(cx=10, cy=10, r=5, stroke=_stroke())
    assert not element_intersects_polygon(ring, _box(9, 9, 11, 11))
    assert element_intersects_polygon(ring, _box(14, 9, 16, 11))


def test_filled_polygon_marquee_wholly_inside_hits():
    sq = Polygon(points=((0, 0), (20, 0), (20, 20), (0, 20)), fill=_fill())
    assert element_intersects_rect(sq, 5, 5, 4, 4)


def test_filled_path_marquee_wholly_inside_hits():
    tri = Path(d=(MoveTo(0, 0), LineTo(20, 0), LineTo(20, 10)), fill=_fill())
    assert element_intersects_rect(tri, 15, 2, 2, 2)


def _donut():
    outer = Rect(x=0, y=0, width=100, height=100)
    hole = Rect(x=30, y=30, width=40, height=40)
    return CompoundShape(operation=CompoundOperation.SUBTRACT_FRONT,
                         operands=(outer, hole))


def test_compound_shape_hole_is_not_the_shape():
    donut = _donut()
    assert not element_intersects_rect(donut, 40, 40, 20, 20)
    assert not element_intersects_polygon(donut, _box(40, 40, 60, 60))
    assert element_intersects_rect(donut, 25, 40, 10, 10)       # crosses the hole's ring
    assert element_intersects_polygon(donut, _box(-5, 40, 5, 50))  # crosses the outer ring


def test_text_path_lasso_enclosing_its_bounds_hits():
    tp = TextPath(d=(MoveTo(0, 0), LineTo(20, 0), LineTo(20, 10)), content="Ab",
                  fill=_fill())
    bx, by, bw, bh = tp.bounds()
    assert bw > 0 and bh > 0
    lasso = _box(bx - 10, by - 10, bx + bw + 10, by + bh + 10)
    assert element_intersects_polygon(tp, lasso)


def test_identity_transform_changes_no_answer_over_the_shared_corpus():
    # The class behind every arm above: an element WITH a transform takes
    # the polygon path, so a kind either path forgets answers differently
    # the moment it gains one. The identity moves no point, so each
    # null-transform element vector in the shared corpus must answer the
    # same with it. Before these arms, 9 of the corpus's 31 did not.
    import dataclasses
    import json
    import os
    from geometry.test_json import parse_element_json

    here = os.path.dirname(os.path.abspath(__file__))
    fixture = os.path.join(here, "..", "..", "test_fixtures", "algorithms",
                           "hit_test.json")
    with open(fixture, encoding="utf-8") as f:
        vectors = json.load(f)
    checked = 0
    for v in vectors:
        if v["function"] not in ("element_intersects_rect",
                                 "element_intersects_polygon"):
            continue
        elem = parse_element_json(v["element"])
        if elem.transform is not None:
            continue
        ident = dataclasses.replace(elem, transform=Transform())
        if v["function"] == "element_intersects_rect":
            plain = element_intersects_rect(elem, *v["args"])
            moved = element_intersects_rect(ident, *v["args"])
        else:
            poly = [tuple(p) for p in v["polygon"]]
            plain = element_intersects_polygon(elem, poly)
            moved = element_intersects_polygon(ident, poly)
        assert plain == moved, (
            f"{v['name']}: {plain} with no transform, {moved} with the identity")
        checked += 1
    # The corpus held 31 such vectors when this was written; a floor, not a
    # pin, so an added vector passes and a lost enumeration does not.
    assert checked >= 31, f"only {checked} null-transform element vectors reached"
