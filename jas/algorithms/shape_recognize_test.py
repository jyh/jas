"""Shape recognition tests. Mirrors jas_dioxus shape_recognize.rs."""

import math

from algorithms.shape_recognize import (
    RecognizeConfig,
    RecognizedArrow,
    RecognizedCircle,
    RecognizedEllipse,
    RecognizedLemniscate,
    RecognizedLine,
    RecognizedRectangle,
    RecognizedRoundRect,
    RecognizedScribble,
    RecognizedTriangle,
    ShapeKind,
    recognize,
    recognize_element,
    recognize_path,
    recognized_to_element,
)
from geometry.element import (
    Circle,
    ClosePath,
    RgbColor,
    Ellipse,
    Line,
    LineTo,
    MoveTo,
    Path,
    Polygon,
    Polyline,
    Rect,
    Stroke,
    Visibility,
)

Pt = tuple[float, float]

# ---------------------------------------------------------------------------
# Deterministic PRNG
# ---------------------------------------------------------------------------

def _lcg(state: list[int]) -> float:
    state[0] = (state[0] * 1664525 + 1013904223) & 0xFFFFFFFFFFFFFFFF
    v = (state[0] >> 11) / (1 << 53)
    return 2.0 * v - 1.0

# ---------------------------------------------------------------------------
# Generators
# ---------------------------------------------------------------------------

def _sample_line(a: Pt, b: Pt, n: int) -> list[Pt]:
    return [(a[0] + (b[0] - a[0]) * i / (n - 1),
             a[1] + (b[1] - a[1]) * i / (n - 1)) for i in range(n)]

def _sample_triangle(a: Pt, b: Pt, c: Pt, n_per_side: int) -> list[Pt]:
    pts = []
    for p, q in [(a, b), (b, c), (c, a)]:
        pts.extend(_sample_line(p, q, n_per_side)[:-1])
    pts.append(a)
    return pts

def _sample_rect(x: float, y: float, w: float, h: float, n_per_side: int) -> list[Pt]:
    p0, p1, p2, p3 = (x, y), (x + w, y), (x + w, y + h), (x, y + h)
    pts = []
    for p, q in [(p0, p1), (p1, p2), (p2, p3), (p3, p0)]:
        pts.extend(_sample_line(p, q, n_per_side)[:-1])
    pts.append(p0)
    return pts

def _sample_round_rect(x: float, y: float, w: float, h: float, r: float, n: int) -> list[Pt]:
    arc_n, side_n = max(n // 16, 4), max(n // 8, 4)
    pts: list[Pt] = []
    def arc(cx, cy, a0, a1, k):
        for i in range(k):
            t = i / k
            a = a0 + (a1 - a0) * t
            pts.append((cx + r * math.cos(a), cy + r * math.sin(a)))
    def line(x0, y0, x1, y1, k):
        for i in range(k):
            t = i / k
            pts.append((x0 + (x1 - x0) * t, y0 + (y1 - y0) * t))
    line(x + r, y, x + w - r, y, side_n)
    arc(x + w - r, y + r, -math.pi / 2, 0, arc_n)
    line(x + w, y + r, x + w, y + h - r, side_n)
    arc(x + w - r, y + h - r, 0, math.pi / 2, arc_n)
    line(x + w - r, y + h, x + r, y + h, side_n)
    arc(x + r, y + h - r, math.pi / 2, math.pi, arc_n)
    line(x, y + h - r, x, y + r, side_n)
    arc(x + r, y + r, math.pi, 3 * math.pi / 2, arc_n)
    pts.append((x + r, y))
    return pts

def _sample_circle(cx: float, cy: float, r: float, n: int) -> list[Pt]:
    return [(cx + r * math.cos(2 * math.pi * i / n),
             cy + r * math.sin(2 * math.pi * i / n)) for i in range(n + 1)]

def _sample_ellipse(cx: float, cy: float, rx: float, ry: float, n: int) -> list[Pt]:
    return [(cx + rx * math.cos(2 * math.pi * i / n),
             cy + ry * math.sin(2 * math.pi * i / n)) for i in range(n + 1)]

def _sample_arrow_outline(tail: Pt, tip: Pt, head_len: float, head_half_w: float, shaft_half_w: float) -> list[Pt]:
    dx, dy = tip[0] - tail[0], tip[1] - tail[1]
    if abs(dy) < 1e-9:
        d = 1.0 if dx > 0 else -1.0
        sex = tip[0] - d * head_len
        corners = [
            (tail[0], tail[1] - shaft_half_w), (sex, tail[1] - shaft_half_w),
            (sex, tail[1] - head_half_w), tip,
            (sex, tail[1] + head_half_w), (sex, tail[1] + shaft_half_w),
            (tail[0], tail[1] + shaft_half_w)]
    else:
        d = 1.0 if dy > 0 else -1.0
        sey = tip[1] - d * head_len
        corners = [
            (tail[0] - shaft_half_w, tail[1]), (tail[0] - shaft_half_w, sey),
            (tail[0] - head_half_w, sey), tip,
            (tail[0] + head_half_w, sey), (tail[0] + shaft_half_w, sey),
            (tail[0] + shaft_half_w, tail[1])]
    pts = []
    for i in range(7):
        side = _sample_line(corners[i], corners[(i + 1) % 7], 10)
        pts.extend(side[:-1])
    pts.append(corners[0])
    return pts

def _sample_lemniscate(cx: float, cy: float, a: float, horizontal: bool, n: int) -> list[Pt]:
    pts = []
    for i in range(n + 1):
        t = 2.0 * math.pi * i / n
        s, c = math.sin(t), math.cos(t)
        denom = 1.0 + s * s
        lx, ly = a * c / denom, a * s * c / denom
        if horizontal:
            pts.append((cx + lx, cy + ly))
        else:
            pts.append((cx + ly, cy + lx))
    return pts

def _sample_zigzag(x_start: float, y_center: float, x_step: float,
                    y_amplitude: float, n_zags: int, pts_per_seg: int) -> list[Pt]:
    vertices = [(x_start + x_step * i,
                 y_center - y_amplitude if i % 2 == 0 else y_center + y_amplitude)
                for i in range(n_zags + 1)]
    pts = []
    for i in range(len(vertices) - 1):
        pts.extend(_sample_line(vertices[i], vertices[i + 1], pts_per_seg)[:-1])
    pts.append(vertices[-1])
    return pts

def _jitter(pts: list[Pt], seed: int, amplitude: float) -> list[Pt]:
    state = [seed]
    return [(x + amplitude * _lcg(state), y + amplitude * _lcg(state)) for x, y in pts]

def _open_gap(pts: list[Pt], frac: float) -> list[Pt]:
    keep = max(int(len(pts) * (1.0 - frac)), 2)
    return pts[:keep]

def _bbox_diag(pts: list[Pt]) -> float:
    xs = [p[0] for p in pts]
    ys = [p[1] for p in pts]
    return math.sqrt((max(xs) - min(xs)) ** 2 + (max(ys) - min(ys)) ** 2)

def _rotate_pts(pts: list[Pt], cx: float, cy: float, theta: float) -> list[Pt]:
    s, c = math.sin(theta), math.cos(theta)
    return [(cx + (x - cx) * c - (y - cy) * s,
             cy + (x - cx) * s + (y - cy) * c) for x, y in pts]

def _assert_close(a: float, b: float, tol: float, name: str):
    assert abs(a - b) <= tol, f"{name}: expected {b}, got {a}, tol {tol}"

cfg = RecognizeConfig()

# ---------------------------------------------------------------------------
# Generator sanity
# ---------------------------------------------------------------------------

def test_generator_circle_has_expected_radius():
    pts = _sample_circle(50, 50, 30, 64)
    for x, y in pts:
        r = math.sqrt((x - 50) ** 2 + (y - 50) ** 2)
        assert abs(r - 30) < 1e-9

def test_generator_round_rect_runs():
    pts = _sample_round_rect(0, 0, 100, 60, 10, 200)
    assert len(pts) > 50

def test_generator_lemniscate_passes_through_origin_offset():
    pts = _sample_lemniscate(100, 100, 40, True, 64)
    assert abs(pts[0][0] - 140) < 1e-9
    assert abs(pts[0][1] - 100) < 1e-9

def test_jitter_is_deterministic():
    pts = _sample_circle(0, 0, 10, 32)
    a = _jitter(pts, 42, 0.5)
    b = _jitter(pts, 42, 0.5)
    assert a == b

# ---------------------------------------------------------------------------
# Clean positive ID
# ---------------------------------------------------------------------------

def test_recognize_clean_line():
    pts = _sample_line((10, 20), (110, 20), 32)
    result = recognize(pts, cfg)
    assert isinstance(result, RecognizedLine)
    tol = 0.02 * _bbox_diag(pts)
    _assert_close(min(result.a[0], result.b[0]), 10, tol, "x_min")
    _assert_close(max(result.a[0], result.b[0]), 110, tol, "x_max")

def test_recognize_clean_triangle():
    pts = _sample_triangle((0, 0), (100, 0), (50, 86.6), 20)
    assert isinstance(recognize(pts, cfg), RecognizedTriangle)

def test_recognize_clean_rectangle():
    pts = _sample_rect(10, 20, 100, 60, 16)
    result = recognize(pts, cfg)
    assert isinstance(result, RecognizedRectangle)
    tol = 0.02 * _bbox_diag(pts)
    _assert_close(result.x, 10, tol, "x")
    _assert_close(result.y, 20, tol, "y")
    _assert_close(result.w, 100, tol, "w")
    _assert_close(result.h, 60, tol, "h")

def test_recognize_clean_square_emits_rectangle_with_equal_sides():
    pts = _sample_rect(0, 0, 80, 80, 16)
    result = recognize(pts, cfg)
    assert isinstance(result, RecognizedRectangle)
    assert abs(result.w - result.h) < 1e-6

def test_recognize_clean_round_rect():
    pts = _sample_round_rect(0, 0, 120, 80, 15, 256)
    result = recognize(pts, cfg)
    assert isinstance(result, RecognizedRoundRect)
    tol = 0.04 * _bbox_diag(pts)
    _assert_close(result.r, 15, tol, "r")

def test_recognize_clean_circle():
    pts = _sample_circle(50, 50, 30, 64)
    result = recognize(pts, cfg)
    assert isinstance(result, RecognizedCircle)
    tol = 0.02 * _bbox_diag(pts)
    _assert_close(result.cx, 50, tol, "cx")
    _assert_close(result.cy, 50, tol, "cy")
    _assert_close(result.r, 30, tol, "r")

def test_recognize_clean_ellipse():
    pts = _sample_ellipse(50, 50, 60, 30, 64)
    result = recognize(pts, cfg)
    assert isinstance(result, RecognizedEllipse)

def test_recognize_clean_arrow_outline():
    pts = _sample_arrow_outline((0, 50), (100, 50), 25, 20, 8)
    result = recognize(pts, cfg)
    assert isinstance(result, RecognizedArrow)
    tol = 0.05 * _bbox_diag(pts)
    _assert_close(result.tail[0], 0, tol, "tail.x")
    _assert_close(result.tip[0], 100, tol, "tip.x")

def test_recognize_clean_lemniscate_horizontal():
    pts = _sample_lemniscate(100, 100, 50, True, 128)
    result = recognize(pts, cfg)
    assert isinstance(result, RecognizedLemniscate)
    assert result.horizontal

def test_recognize_clean_lemniscate_vertical():
    pts = _sample_lemniscate(0, 0, 30, False, 128)
    result = recognize(pts, cfg)
    assert isinstance(result, RecognizedLemniscate)
    assert not result.horizontal

# ---------------------------------------------------------------------------
# Noisy positive ID
# ---------------------------------------------------------------------------

def test_recognize_noisy_circle():
    clean = _sample_circle(50, 50, 30, 64)
    pts = _jitter(clean, 1, 0.03 * _bbox_diag(clean))
    assert isinstance(recognize(pts, cfg), RecognizedCircle)

def test_recognize_noisy_rectangle():
    clean = _sample_rect(0, 0, 100, 60, 16)
    pts = _jitter(clean, 2, 0.03 * _bbox_diag(clean))
    assert isinstance(recognize(pts, cfg), RecognizedRectangle)

def test_recognize_noisy_ellipse():
    clean = _sample_ellipse(0, 0, 60, 30, 64)
    pts = _jitter(clean, 3, 0.03 * _bbox_diag(clean))
    assert isinstance(recognize(pts, cfg), RecognizedEllipse)

def test_recognize_noisy_triangle():
    clean = _sample_triangle((0, 0), (100, 0), (50, 86.6), 20)
    pts = _jitter(clean, 4, 0.03 * _bbox_diag(clean))
    assert isinstance(recognize(pts, cfg), RecognizedTriangle)

# ---------------------------------------------------------------------------
# Closed/open dispatch
# ---------------------------------------------------------------------------

def test_nearly_closed_polyline_treated_as_closed():
    clean = _sample_rect(0, 0, 100, 60, 16)
    pts = _open_gap(clean, 0.05)
    assert isinstance(recognize(pts, cfg), RecognizedRectangle)

def test_clearly_open_polyline_not_rectangle():
    clean = _sample_rect(0, 0, 100, 60, 16)
    pts = _open_gap(clean, 0.25)
    assert not isinstance(recognize(pts, cfg), RecognizedRectangle)

def test_recognize_path_via_bezier_input():
    d = (MoveTo(x=0, y=0), LineTo(x=100, y=0), LineTo(x=100, y=100),
         LineTo(x=0, y=100), ClosePath())
    assert isinstance(recognize_path(d, cfg), RecognizedRectangle)

# ---------------------------------------------------------------------------
# Disambiguation
# ---------------------------------------------------------------------------

def test_square_with_aspect_1_04_is_square():
    pts = _sample_rect(0, 0, 104, 100, 16)
    result = recognize(pts, cfg)
    assert isinstance(result, RecognizedRectangle)
    assert abs(result.w - result.h) < 1e-6

def test_rect_with_aspect_1_15_is_not_square():
    pts = _sample_rect(0, 0, 115, 100, 16)
    result = recognize(pts, cfg)
    assert isinstance(result, RecognizedRectangle)
    assert abs(result.w - result.h) > 1.0

def test_nearly_circular_ellipse_is_circle():
    pts = _sample_ellipse(0, 0, 30, 29.5, 64)
    assert isinstance(recognize(pts, cfg), RecognizedCircle)

def test_clearly_elliptical_is_ellipse():
    pts = _sample_ellipse(0, 0, 30, 15, 64)
    assert isinstance(recognize(pts, cfg), RecognizedEllipse)

def test_tiny_corner_radius_is_plain_rect():
    pts = _sample_round_rect(0, 0, 100, 60, 1, 256)
    assert isinstance(recognize(pts, cfg), RecognizedRectangle)

def test_flat_triangle_is_line():
    pts = _sample_triangle((0, 0), (100, 0), (50, 0.5), 20)
    assert isinstance(recognize(pts, cfg), RecognizedLine)

def test_random_scribble_returns_none():
    state = [99]
    pts = [(50 + 50 * _lcg(state), 50 + 50 * _lcg(state)) for _ in range(64)]
    assert recognize(pts, cfg) is None

def test_nearly_straight_arrow_outline_still_recognized():
    pts = _sample_arrow_outline((0, 50), (200, 50), 20, 15, 4)
    assert isinstance(recognize(pts, cfg), RecognizedArrow)

def test_tilted_square_returns_none():
    clean = _sample_rect(-50, -50, 100, 100, 16)
    pts = _rotate_pts(clean, 0, 0, math.radians(30))
    assert not isinstance(recognize(pts, cfg), RecognizedRectangle)

def test_lemniscate_off_center_crossing_returns_none():
    pts = _sample_lemniscate(0, 0, 50, True, 128)
    skewed = [(x + 30, y) if x > 0 else (x, y) for x, y in pts]
    assert recognize(skewed, cfg) is None

# ---------------------------------------------------------------------------
# Element conversion
# ---------------------------------------------------------------------------

def test_recognized_to_element_preserves_stroke_and_common():
    template = Path(d=(), stroke=Stroke(color=RgbColor(0, 0, 0), width=2.5), opacity=0.7)
    shape = RecognizedRectangle(x=10, y=20, w=30, h=40)
    result = recognized_to_element(shape, template)
    assert isinstance(result, Rect)
    assert result.x == 10 and result.width == 30 and result.height == 40
    assert result.rx == 0.0
    assert abs(result.stroke.width - 2.5) < 1e-9
    assert abs(result.opacity - 0.7) < 1e-9

def test_recognized_to_element_round_rect_sets_rx_ry():
    template = Path(d=())
    shape = RecognizedRoundRect(x=0, y=0, w=100, h=60, r=12)
    result = recognized_to_element(shape, template)
    assert isinstance(result, Rect)
    assert result.rx == 12 and result.ry == 12

def test_recognized_to_element_arrow_emits_polygon():
    template = Path(d=())
    shape = RecognizedArrow(tail=(0, 0), tip=(100, 0), head_len=25,
                            head_half_width=20, shaft_half_width=8)
    result = recognized_to_element(shape, template)
    assert isinstance(result, Polygon)
    assert len(result.points) == 7
    assert abs(result.points[3][0] - 100) < 1e-9

# ---------------------------------------------------------------------------
# Scribble
# ---------------------------------------------------------------------------

def test_recognize_clean_zigzag_scribble():
    pts = _sample_zigzag(0, 50, 20, 30, 8, 10)
    result = recognize(pts, cfg)
    assert isinstance(result, RecognizedScribble)
    assert len(result.points) >= 5

def test_recognize_noisy_zigzag_scribble():
    clean = _sample_zigzag(0, 50, 15, 25, 10, 10)
    pts = _jitter(clean, 7, 0.02 * _bbox_diag(clean))
    assert isinstance(recognize(pts, cfg), RecognizedScribble)

def test_straight_line_not_scribble():
    pts = _sample_line((0, 0), (200, 0), 64)
    result = recognize(pts, cfg)
    assert not isinstance(result, RecognizedScribble)
    assert isinstance(result, RecognizedLine)

def test_diagonal_line_not_scribble():
    pts = _sample_line((0, 0), (100, 80), 64)
    assert isinstance(recognize(pts, cfg), RecognizedLine)

def test_recognized_to_element_scribble_emits_polyline():
    template = Path(d=())
    shape = RecognizedScribble(points=((0, 0), (10, 20), (20, 0), (30, 20), (40, 0)))
    result = recognized_to_element(shape, template)
    assert isinstance(result, Polyline)
    assert len(result.points) == 5

# ---------------------------------------------------------------------------
# recognize_element
# ---------------------------------------------------------------------------

def test_recognize_element_skips_line():
    elem = Line(x1=0, y1=0, x2=100, y2=0)
    assert recognize_element(elem, cfg) is None

def test_recognize_element_skips_rect():
    elem = Rect(x=0, y=0, width=100, height=60)
    assert recognize_element(elem, cfg) is None

def test_recognize_element_skips_circle():
    elem = Circle(cx=50, cy=50, r=30)
    assert recognize_element(elem, cfg) is None

def test_recognize_element_skips_polygon():
    elem = Polygon(points=((0, 0), (100, 0), (50, 86.6)))
    assert recognize_element(elem, cfg) is None

def test_recognize_element_converts_path_circle():
    pts = _sample_circle(50, 50, 30, 64)
    d = tuple(MoveTo(x=p[0], y=p[1]) if i == 0 else LineTo(x=p[0], y=p[1])
              for i, p in enumerate(pts))
    elem = Path(d=d)
    result = recognize_element(elem, cfg)
    assert result is not None
    kind, el = result
    assert kind == ShapeKind.CIRCLE
    assert isinstance(el, Circle)

def test_recognize_element_square_returns_square_kind():
    pts = _sample_rect(0, 0, 80, 80, 16)
    d = tuple(MoveTo(x=p[0], y=p[1]) if i == 0 else LineTo(x=p[0], y=p[1])
              for i, p in enumerate(pts))
    elem = Path(d=d)
    result = recognize_element(elem, cfg)
    assert result is not None
    kind, el = result
    assert kind == ShapeKind.SQUARE
    assert isinstance(el, Rect)
