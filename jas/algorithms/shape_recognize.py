"""Shape recognition: classify a freehand path as the nearest geometric
primitive (line, scribble, triangle, rectangle, rounded rectangle,
circle, ellipse, filled-arrow outline, or lemniscate)."""

from __future__ import annotations

import math
from dataclasses import dataclass
from enum import Enum

from geometry.element import (
    Circle as CircleElem,
    ClosePath,
    Element,
    Ellipse as EllipseElem,
    Fill,
    Group,
    Layer,
    Line as LineElem,
    LineTo,
    MoveTo,
    Path as PathElem,
    Polygon as PolygonElem,
    Polyline as PolylineElem,
    Rect as RectElem,
    Stroke,
    Text,
    TextPath,
    Transform,
    Visibility,
    flatten_path_commands,
)

Pt = tuple[float, float]


class ShapeKind(Enum):
    LINE = "line"
    TRIANGLE = "triangle"
    RECTANGLE = "rectangle"
    SQUARE = "square"
    ROUND_RECT = "round_rect"
    CIRCLE = "circle"
    ELLIPSE = "ellipse"
    ARROW = "arrow"
    LEMNISCATE = "lemniscate"
    SCRIBBLE = "scribble"


@dataclass(frozen=True)
class RecognizedLine:
    a: Pt
    b: Pt

    @property
    def kind(self) -> ShapeKind:
        return ShapeKind.LINE


@dataclass(frozen=True)
class RecognizedTriangle:
    pts: tuple[Pt, Pt, Pt]

    @property
    def kind(self) -> ShapeKind:
        return ShapeKind.TRIANGLE


@dataclass(frozen=True)
class RecognizedRectangle:
    x: float
    y: float
    w: float
    h: float

    @property
    def kind(self) -> ShapeKind:
        return ShapeKind.SQUARE if abs(self.w - self.h) < 1e-9 else ShapeKind.RECTANGLE


@dataclass(frozen=True)
class RecognizedRoundRect:
    x: float
    y: float
    w: float
    h: float
    r: float

    @property
    def kind(self) -> ShapeKind:
        return ShapeKind.ROUND_RECT


@dataclass(frozen=True)
class RecognizedCircle:
    cx: float
    cy: float
    r: float

    @property
    def kind(self) -> ShapeKind:
        return ShapeKind.CIRCLE


@dataclass(frozen=True)
class RecognizedEllipse:
    cx: float
    cy: float
    rx: float
    ry: float

    @property
    def kind(self) -> ShapeKind:
        return ShapeKind.ELLIPSE


@dataclass(frozen=True)
class RecognizedArrow:
    tail: Pt
    tip: Pt
    head_len: float
    head_half_width: float
    shaft_half_width: float

    @property
    def kind(self) -> ShapeKind:
        return ShapeKind.ARROW


@dataclass(frozen=True)
class RecognizedLemniscate:
    center: Pt
    a: float
    horizontal: bool

    @property
    def kind(self) -> ShapeKind:
        return ShapeKind.LEMNISCATE


@dataclass(frozen=True)
class RecognizedScribble:
    points: tuple[Pt, ...]

    @property
    def kind(self) -> ShapeKind:
        return ShapeKind.SCRIBBLE


RecognizedShape = (
    RecognizedLine
    | RecognizedTriangle
    | RecognizedRectangle
    | RecognizedRoundRect
    | RecognizedCircle
    | RecognizedEllipse
    | RecognizedArrow
    | RecognizedLemniscate
    | RecognizedScribble
)


@dataclass(frozen=True)
class RecognizeConfig:
    tolerance: float = 0.05
    close_gap_frac: float = 0.10
    corner_angle_deg: float = 35.0
    square_aspect_eps: float = 0.10
    circle_eccentricity_eps: float = 0.92
    resample_n: int = 64


_MIN_CLOSED_BBOX_ASPECT = 0.10


# ---------------------------------------------------------------------------
# Geometric helpers
# ---------------------------------------------------------------------------

def _dist(a: Pt, b: Pt) -> float:
    return math.sqrt((a[0] - b[0]) ** 2 + (a[1] - b[1]) ** 2)


def _bbox_of(pts: list[Pt]) -> tuple[float, float, float, float]:
    xs = [p[0] for p in pts]
    ys = [p[1] for p in pts]
    return min(xs), min(ys), max(xs), max(ys)


def _bbox_diag_of(pts: list[Pt]) -> float:
    xmin, ymin, xmax, ymax = _bbox_of(pts)
    return math.sqrt((xmax - xmin) ** 2 + (ymax - ymin) ** 2)


def _arc_length(pts: list[Pt]) -> float:
    return sum(_dist(pts[i], pts[i + 1]) for i in range(len(pts) - 1))


def _is_closed(pts: list[Pt], frac: float) -> bool:
    if len(pts) < 2:
        return False
    total = _arc_length(pts)
    if total < 1e-12:
        return False
    return _dist(pts[0], pts[-1]) / total <= frac


def _resample(pts: list[Pt], n: int) -> list[Pt]:
    if len(pts) < 2 or n < 2:
        return list(pts)
    cum = [0.0]
    for i in range(1, len(pts)):
        cum.append(cum[-1] + _dist(pts[i - 1], pts[i]))
    total = cum[-1]
    if total < 1e-12:
        return list(pts)
    step = total / (n - 1)
    out = [pts[0]]
    idx = 1
    for k in range(1, n - 1):
        target = step * k
        while idx < len(pts) - 1 and cum[idx] < target:
            idx += 1
        seg_start = cum[idx - 1]
        seg_len = cum[idx] - seg_start
        t = max(0.0, min(1.0, (target - seg_start) / seg_len)) if seg_len > 1e-12 else 0.0
        x = pts[idx - 1][0] + t * (pts[idx][0] - pts[idx - 1][0])
        y = pts[idx - 1][1] + t * (pts[idx][1] - pts[idx - 1][1])
        out.append((x, y))
    out.append(pts[-1])
    return out


def _point_to_segment_dist(p: Pt, a: Pt, b: Pt) -> float:
    dx, dy = b[0] - a[0], b[1] - a[1]
    len2 = dx * dx + dy * dy
    if len2 < 1e-12:
        return _dist(p, a)
    t = max(0.0, min(1.0, ((p[0] - a[0]) * dx + (p[1] - a[1]) * dy) / len2))
    qx, qy = a[0] + t * dx, a[1] + t * dy
    return math.sqrt((p[0] - qx) ** 2 + (p[1] - qy) ** 2)


def _point_to_line_dist(p: Pt, a: Pt, b: Pt) -> float:
    dx, dy = b[0] - a[0], b[1] - a[1]
    length = math.sqrt(dx * dx + dy * dy)
    if length < 1e-12:
        return _dist(p, a)
    return abs((p[0] - a[0]) * dy - (p[1] - a[1]) * dx) / length


# ---------------------------------------------------------------------------
# Fits
# ---------------------------------------------------------------------------

def _fit_line(pts: list[Pt]) -> tuple[Pt, Pt, float | None]:
    n = len(pts)
    if n < 2:
        return None
    nf = float(n)
    cx = sum(p[0] for p in pts) / nf
    cy = sum(p[1] for p in pts) / nf
    sxx = syy = sxy = 0.0
    for x, y in pts:
        sxx += (x - cx) ** 2
        syy += (y - cy) ** 2
        sxy += (x - cx) * (y - cy)
    trace = sxx + syy
    det = sxx * syy - sxy * sxy
    disc = math.sqrt(max(0.0, trace * trace / 4.0 - det))
    lambda1 = trace / 2.0 + disc
    if abs(sxy) > 1e-12:
        dx, dy = lambda1 - syy, sxy
    elif sxx >= syy:
        dx, dy = 1.0, 0.0
    else:
        dx, dy = 0.0, 1.0
    length = math.sqrt(dx * dx + dy * dy)
    if length < 1e-12:
        return None
    dx /= length
    dy /= length
    tmin, tmax = math.inf, -math.inf
    sq_sum = 0.0
    for x, y in pts:
        t = (x - cx) * dx + (y - cy) * dy
        tmin = min(tmin, t)
        tmax = max(tmax, t)
        perp = (x - cx) * (-dy) + (y - cy) * dx
        sq_sum += perp * perp
    rms = math.sqrt(sq_sum / nf)
    a = (cx + tmin * dx, cy + tmin * dy)
    b = (cx + tmax * dx, cy + tmax * dy)
    return a, b, rms


def _fit_ellipse_aa(pts: list[Pt]) -> tuple[float, float, float, float, float | None]:
    xmin, ymin, xmax, ymax = _bbox_of(pts)
    rx, ry = (xmax - xmin) / 2.0, (ymax - ymin) / 2.0
    if rx <= 1e-9 or ry <= 1e-9:
        return None
    if min(rx, ry) / max(rx, ry) < _MIN_CLOSED_BBOX_ASPECT:
        return None
    cx, cy = (xmin + xmax) / 2.0, (ymin + ymax) / 2.0
    scale = min(rx, ry)
    sq_sum = 0.0
    for x, y in pts:
        nx, ny = (x - cx) / rx, (y - cy) / ry
        r = math.sqrt(nx * nx + ny * ny)
        d = (r - 1.0) * scale
        sq_sum += d * d
    return cx, cy, rx, ry, math.sqrt(sq_sum / len(pts))


def _fit_rect_aa(pts: list[Pt]) -> tuple[float, float, float, float, float | None]:
    xmin, ymin, xmax, ymax = _bbox_of(pts)
    w, h = xmax - xmin, ymax - ymin
    if w <= 1e-9 or h <= 1e-9:
        return None
    if min(w, h) / max(w, h) < _MIN_CLOSED_BBOX_ASPECT:
        return None
    sq_sum = 0.0
    for x, y in pts:
        dx = min(abs(x - xmin), abs(x - xmax))
        dy = min(abs(y - ymin), abs(y - ymax))
        sq_sum += min(dx, dy) ** 2
    return xmin, ymin, w, h, math.sqrt(sq_sum / len(pts))


def _dist_to_round_rect(p: Pt, x: float, y: float, w: float, h: float, r: float) -> float:
    px, py = p[0] - x, p[1] - y
    qx = w - px if px > w / 2.0 else px
    qy = h - py if py > h / 2.0 else py
    if qx >= r and qy >= r:
        return min(qx, qy)
    elif qx >= r:
        return qy
    elif qy >= r:
        return qx
    else:
        dx, dy = qx - r, qy - r
        return abs(math.sqrt(dx * dx + dy * dy) - r)


def _round_rect_rms(pts: list[Pt], x: float, y: float, w: float, h: float, r: float) -> float:
    sq_sum = sum(_dist_to_round_rect(p, x, y, w, h, r) ** 2 for p in pts)
    return math.sqrt(sq_sum / len(pts))


def _fit_round_rect(pts: list[Pt]) -> tuple[float, float, float, float, float, float | None]:
    xmin, ymin, xmax, ymax = _bbox_of(pts)
    w, h = xmax - xmin, ymax - ymin
    if w <= 1e-9 or h <= 1e-9:
        return None
    if min(w, h) / max(w, h) < _MIN_CLOSED_BBOX_ASPECT:
        return None
    r_max = min(w, h) / 2.0
    n_steps = 40
    best_r, best_rms = 0.0, math.inf
    for i in range(n_steps + 1):
        r = r_max * i / n_steps
        rms = _round_rect_rms(pts, xmin, ymin, w, h, r)
        if rms < best_rms:
            best_rms, best_r = rms, r
    step = r_max / n_steps
    lo, hi = max(best_r - step, 0.0), min(best_r + step, r_max)
    for _ in range(30):
        m1 = lo + (hi - lo) * 0.382
        m2 = lo + (hi - lo) * 0.618
        if _round_rect_rms(pts, xmin, ymin, w, h, m1) < _round_rect_rms(pts, xmin, ymin, w, h, m2):
            hi = m2
        else:
            lo = m1
    r = (lo + hi) / 2.0
    rms = _round_rect_rms(pts, xmin, ymin, w, h, r)
    return xmin, ymin, w, h, r, rms


def _rdp(pts: list[Pt], epsilon: float) -> list[Pt]:
    if len(pts) < 3:
        return list(pts)
    keep = [False] * len(pts)
    keep[0] = keep[-1] = True

    def recurse(start: int, end: int) -> None:
        if end <= start + 1:
            return
        a, b = pts[start], pts[end]
        max_d, max_i = 0.0, start
        for i in range(start + 1, end):
            d = _point_to_segment_dist(pts[i], a, b)
            if d > max_d:
                max_d, max_i = d, i
        if max_d > epsilon:
            keep[max_i] = True
            recurse(start, max_i)
            recurse(max_i, end)

    recurse(0, len(pts) - 1)
    return [pts[i] for i in range(len(pts)) if keep[i]]


def _fit_scribble(pts: list[Pt], diag: float) -> tuple[list[Pt | None, float]]:
    if len(pts) < 6:
        return None
    if _arc_length(pts) < 1.5 * diag:
        return None
    eps = 0.05 * diag
    simplified = _rdp(pts, eps)
    if len(simplified) < 5:
        return None
    sign_changes = 0
    last_sign = 0.0
    for i in range(1, len(simplified) - 1):
        prev, curr, nxt = simplified[i - 1], simplified[i], simplified[i + 1]
        v1 = (curr[0] - prev[0], curr[1] - prev[1])
        v2 = (nxt[0] - curr[0], nxt[1] - curr[1])
        cross = v1[0] * v2[1] - v1[1] * v2[0]
        if abs(cross) < 1e-9:
            continue
        sign = 1.0 if cross > 0 else -1.0
        if last_sign != 0.0 and sign != last_sign:
            sign_changes += 1
        last_sign = sign
    if sign_changes < 2:
        return None
    sq_sum = 0.0
    for p in pts:
        min_d = math.inf
        for i in range(len(simplified) - 1):
            d = _point_to_segment_dist(p, simplified[i], simplified[i + 1])
            if d < min_d:
                min_d = d
        sq_sum += min_d ** 2
    return simplified, math.sqrt(sq_sum / len(pts))


def _fit_triangle(pts: list[Pt]) -> tuple[tuple[Pt, Pt, Pt | None, float]]:
    n = len(pts)
    if n < 3:
        return None
    max_d, ai, bi = 0.0, 0, 0
    for i in range(n):
        for j in range(i + 1, n):
            d = _dist(pts[i], pts[j])
            if d > max_d:
                max_d, ai, bi = d, i, j
    if max_d < 1e-9:
        return None
    pa, pb = pts[ai], pts[bi]
    max_perp, ci = 0.0, 0
    for i, p in enumerate(pts):
        if i == ai or i == bi:
            continue
        d = _point_to_line_dist(p, pa, pb)
        if d > max_perp:
            max_perp, ci = d, i
    if max_perp < 1e-9 or max_perp / max_d < 0.05:
        return None
    pc = pts[ci]
    edges = [(pa, pb), (pb, pc), (pc, pa)]
    sq_sum = 0.0
    for p in pts:
        min_d = min(_point_to_segment_dist(p, e0, e1) for e0, e1 in edges)
        sq_sum += min_d ** 2
    return (pa, pb, pc), math.sqrt(sq_sum / n)


def _count_self_intersections(pts: list[Pt]) -> int:
    def ccw(a: Pt, b: Pt, c: Pt) -> float:
        return (b[0] - a[0]) * (c[1] - a[1]) - (b[1] - a[1]) * (c[0] - a[0])

    n = len(pts)
    if n < 4:
        return 0
    n_segs = n - 1
    count = 0
    for i in range(n_segs):
        for j in range(i + 2, n_segs):
            if i == 0 and j == n_segs - 1:
                if _dist(pts[0], pts[-1]) < 1e-6:
                    continue
            d1 = ccw(pts[j], pts[j + 1], pts[i])
            d2 = ccw(pts[j], pts[j + 1], pts[i + 1])
            d3 = ccw(pts[i], pts[i + 1], pts[j])
            d4 = ccw(pts[i], pts[i + 1], pts[j + 1])
            if d1 * d2 < 0 and d3 * d4 < 0:
                count += 1
    return count


def _fit_lemniscate(pts: list[Pt]) -> tuple[float, float, float, bool, float | None]:
    xmin, ymin, xmax, ymax = _bbox_of(pts)
    w, h = xmax - xmin, ymax - ymin
    if w <= 1e-9 or h <= 1e-9:
        return None
    cx, cy = (xmin + xmax) / 2.0, (ymin + ymax) / 2.0
    horizontal = w >= h
    a = w / 2.0 if horizontal else h / 2.0
    cross = h if horizontal else w
    expected_cross = a * math.sqrt(2.0) / 2.0
    if abs(cross / expected_cross - 1.0) > 0.20:
        return None
    n_samples = 200
    samples = []
    for i in range(n_samples):
        t = 2.0 * math.pi * i / n_samples
        s, c = math.sin(t), math.cos(t)
        denom = 1.0 + s * s
        lx, ly = a * c / denom, a * s * c / denom
        if horizontal:
            samples.append((cx + lx, cy + ly))
        else:
            samples.append((cx + ly, cy + lx))
    sq_sum = 0.0
    for p in pts:
        min_d_sq = min((p[0] - s[0]) ** 2 + (p[1] - s[1]) ** 2 for s in samples)
        sq_sum += min_d_sq
    return cx, cy, a, horizontal, math.sqrt(sq_sum / len(pts))


def _fit_arrow(pts: list[Pt], diag: float) -> tuple[Pt, Pt, float, float, float, float | None]:
    if len(pts) < 7:
        return None
    corners: list[Pt] = []
    for frac in [0.04, 0.02, 0.01, 0.005]:
        eps = frac * diag
        s = _rdp(pts, eps)
        if len(s) >= 2 and _dist(s[0], s[-1]) < max(eps, 1e-6):
            s = s[:-1]
        if len(s) == 7:
            corners = s
            break
    if len(corners) != 7:
        return None
    n = 7
    cross_signs = []
    for i in range(n):
        prev, curr, nxt = corners[(i + n - 1) % n], corners[i], corners[(i + 1) % n]
        v1 = (prev[0] - curr[0], prev[1] - curr[1])
        v2 = (nxt[0] - curr[0], nxt[1] - curr[1])
        cross_signs.append(v2[0] * v1[1] - v2[1] * v1[0])
    positives = sum(1 for s in cross_signs if s > 0)
    negatives = n - positives
    if max(positives, negatives) != 5 or min(positives, negatives) != 2:
        return None
    majority_positive = positives > negatives
    is_majority = lambda s: (s > 0) == majority_positive
    tip_idx = None
    for i in range(n):
        if (is_majority(cross_signs[i]) and is_majority(cross_signs[(i + n - 1) % n])
                and is_majority(cross_signs[(i + 1) % n])):
            if tip_idx is not None:
                return None
            tip_idx = i
    if tip_idx is None:
        return None
    tip = corners[tip_idx]
    c = lambda k: corners[(tip_idx + k) % n]
    head_back_a, head_back_b = c(-1), c(1)
    shaft_end_a, shaft_end_b = c(-2), c(2)
    tail_a, tail_b = c(-3), c(3)
    tail = ((tail_a[0] + tail_b[0]) / 2.0, (tail_a[1] + tail_b[1]) / 2.0)
    dx, dy = tip[0] - tail[0], tip[1] - tail[1]
    length = math.sqrt(dx * dx + dy * dy)
    if length < 1e-9:
        return None
    if max(abs(dx / length), abs(dy / length)) < 0.95:
        return None
    shaft_half_width = _dist(tail_a, tail_b) / 2.0
    head_half_width = _dist(head_back_a, head_back_b) / 2.0
    shaft_end_mid = ((shaft_end_a[0] + shaft_end_b[0]) / 2.0,
                     (shaft_end_a[1] + shaft_end_b[1]) / 2.0)
    head_len = _dist(tip, shaft_end_mid)
    if head_half_width <= shaft_half_width or shaft_half_width < 1e-6 or head_len < 1e-6:
        return None
    arrow_corners = [tail_a, shaft_end_a, head_back_a, tip, head_back_b, shaft_end_b, tail_b]
    edges = [(arrow_corners[i], arrow_corners[(i + 1) % 7]) for i in range(7)]
    sq_sum = 0.0
    for p in pts:
        min_d = min(_point_to_segment_dist(p, e0, e1) for e0, e1 in edges)
        sq_sum += min_d ** 2
    return tail, tip, head_len, head_half_width, shaft_half_width, math.sqrt(sq_sum / len(pts))


# ---------------------------------------------------------------------------
# Public API
# ---------------------------------------------------------------------------

def recognize(points: list[Pt], cfg: RecognizeConfig) -> RecognizedShape | None:
    if len(points) < 3:
        return None
    pts = _resample(points, cfg.resample_n)
    diag = _bbox_diag_of(pts)
    if diag < 1e-9:
        return None
    closed = _is_closed(pts, cfg.close_gap_frac)
    tol_abs = cfg.tolerance * diag
    candidates: list[tuple[float, RecognizedShape]] = []

    # Line
    result = _fit_line(pts)
    if result is not None:
        a, b, res = result
        if res <= tol_abs:
            candidates.append((res, RecognizedLine(a=a, b=b)))

    # Scribble (open only)
    if not closed:
        result = _fit_scribble(pts, diag)
        if result is not None:
            segs, res = result
            if res <= tol_abs:
                candidates.append((res, RecognizedScribble(points=tuple(segs))))

    if closed:
        # Ellipse
        result = _fit_ellipse_aa(pts)
        if result is not None:
            cx, cy, rx, ry, res = result
            if res <= tol_abs:
                ratio = min(rx, ry) / max(rx, ry)
                if ratio >= cfg.circle_eccentricity_eps:
                    r = (rx + ry) / 2.0
                    candidates.append((res, RecognizedCircle(cx=cx, cy=cy, r=r)))
                else:
                    candidates.append((res, RecognizedEllipse(cx=cx, cy=cy, rx=rx, ry=ry)))

        # Rectangle
        rect_fit = _fit_rect_aa(pts)
        if rect_fit is not None:
            x, y, w, h, res = rect_fit
            if res <= tol_abs:
                aspect = abs(w - h) / max(w, h)
                if aspect <= cfg.square_aspect_eps:
                    m = (w + h) / 2.0
                    w, h = m, m
                candidates.append((res, RecognizedRectangle(x=x, y=y, w=w, h=h)))

        # Round rect
        result = _fit_round_rect(pts)
        if result is not None:
            x, y, w, h, r, res = result
            short = min(w, h)
            rect_rms = rect_fit[4] if rect_fit else math.inf
            if res <= tol_abs and r / short > 0.05 and r / short < 0.45 and res < 0.5 * rect_rms:
                candidates.append((res, RecognizedRoundRect(x=x, y=y, w=w, h=h, r=r)))

        # Triangle
        result = _fit_triangle(pts)
        if result is not None:
            verts, res = result
            if res <= tol_abs:
                candidates.append((res, RecognizedTriangle(pts=verts)))

        # Lemniscate
        if _count_self_intersections(pts) >= 1:
            result = _fit_lemniscate(pts)
            if result is not None:
                cx, cy, a, horizontal, res = result
                if res <= tol_abs:
                    candidates.append((res, RecognizedLemniscate(center=(cx, cy), a=a, horizontal=horizontal)))

        # Arrow
        result = _fit_arrow(points, diag)
        if result is not None:
            tail, tip, head_len, head_half_width, shaft_half_width, res = result
            if res <= tol_abs:
                candidates.append((res, RecognizedArrow(
                    tail=tail, tip=tip, head_len=head_len,
                    head_half_width=head_half_width, shaft_half_width=shaft_half_width)))

    if not candidates:
        return None
    candidates.sort(key=lambda c: c[0])
    return candidates[0][1]


def recognize_path(d: tuple, cfg: RecognizeConfig) -> RecognizedShape | None:
    pts = flatten_path_commands(d)
    return recognize(pts, cfg)


@dataclass(frozen=True)
class _Appearance:
    fill: Fill | None
    stroke: Stroke | None
    opacity: float
    transform: Transform | None
    locked: bool
    visibility: Visibility


def _template_appearance(e: Element) -> _Appearance:
    if isinstance(e, LineElem):
        return _Appearance(None, e.stroke, e.opacity, e.transform, e.locked, e.visibility)
    elif isinstance(e, (RectElem, CircleElem, EllipseElem, PolylineElem, PolygonElem, PathElem)):
        return _Appearance(e.fill, e.stroke, e.opacity, e.transform, e.locked, e.visibility)
    else:
        return _Appearance(None, None, 1.0, None, False, Visibility.PREVIEW)


def recognized_to_element(shape: RecognizedShape, template: Element) -> Element:
    a = _template_appearance(template)
    if isinstance(shape, RecognizedLine):
        return LineElem(x1=shape.a[0], y1=shape.a[1], x2=shape.b[0], y2=shape.b[1],
                        stroke=a.stroke, opacity=a.opacity, transform=a.transform,
                        locked=a.locked, visibility=a.visibility)
    elif isinstance(shape, RecognizedTriangle):
        return PolygonElem(points=shape.pts,
                           fill=a.fill, stroke=a.stroke, opacity=a.opacity,
                           transform=a.transform, locked=a.locked, visibility=a.visibility)
    elif isinstance(shape, RecognizedRectangle):
        return RectElem(x=shape.x, y=shape.y, width=shape.w, height=shape.h,
                        fill=a.fill, stroke=a.stroke, opacity=a.opacity,
                        transform=a.transform, locked=a.locked, visibility=a.visibility)
    elif isinstance(shape, RecognizedRoundRect):
        return RectElem(x=shape.x, y=shape.y, width=shape.w, height=shape.h,
                        rx=shape.r, ry=shape.r,
                        fill=a.fill, stroke=a.stroke, opacity=a.opacity,
                        transform=a.transform, locked=a.locked, visibility=a.visibility)
    elif isinstance(shape, RecognizedCircle):
        return CircleElem(cx=shape.cx, cy=shape.cy, r=shape.r,
                          fill=a.fill, stroke=a.stroke, opacity=a.opacity,
                          transform=a.transform, locked=a.locked, visibility=a.visibility)
    elif isinstance(shape, RecognizedEllipse):
        return EllipseElem(cx=shape.cx, cy=shape.cy, rx=shape.rx, ry=shape.ry,
                           fill=a.fill, stroke=a.stroke, opacity=a.opacity,
                           transform=a.transform, locked=a.locked, visibility=a.visibility)
    elif isinstance(shape, RecognizedArrow):
        dx, dy = shape.tip[0] - shape.tail[0], shape.tip[1] - shape.tail[1]
        length = math.sqrt(dx * dx + dy * dy)
        ux, uy = (dx / length, dy / length) if length > 1e-9 else (1.0, 0.0)
        px, py = -uy, ux
        shaft_end = (shape.tip[0] - ux * shape.head_len, shape.tip[1] - uy * shape.head_len)
        def p(c: Pt, s: float) -> Pt:
            return (c[0] + px * s, c[1] + py * s)
        points = tuple([
            p(shape.tail, -shape.shaft_half_width),
            p(shaft_end, -shape.shaft_half_width),
            p(shaft_end, -shape.head_half_width),
            shape.tip,
            p(shaft_end, shape.head_half_width),
            p(shaft_end, shape.shaft_half_width),
            p(shape.tail, shape.shaft_half_width),
        ])
        return PolygonElem(points=points,
                           fill=a.fill, stroke=a.stroke, opacity=a.opacity,
                           transform=a.transform, locked=a.locked, visibility=a.visibility)
    elif isinstance(shape, RecognizedScribble):
        return PolylineElem(points=shape.points,
                            stroke=a.stroke, opacity=a.opacity,
                            transform=a.transform, locked=a.locked, visibility=a.visibility)
    elif isinstance(shape, RecognizedLemniscate):
        n = 96
        d_cmds = []
        for i in range(n + 1):
            t = 2.0 * math.pi * i / n
            s, c = math.sin(t), math.cos(t)
            denom = 1.0 + s * s
            lx, ly = shape.a * c / denom, shape.a * s * c / denom
            if shape.horizontal:
                x, y = shape.center[0] + lx, shape.center[1] + ly
            else:
                x, y = shape.center[0] + ly, shape.center[1] + lx
            if i == 0:
                d_cmds.append(MoveTo(x=x, y=y))
            else:
                d_cmds.append(LineTo(x=x, y=y))
        d_cmds.append(ClosePath())
        return PathElem(d=tuple(d_cmds),
                        fill=a.fill, stroke=a.stroke, opacity=a.opacity,
                        transform=a.transform, locked=a.locked, visibility=a.visibility)
    else:
        raise ValueError(f"Unknown shape: {shape}")


def recognize_element(element: Element, cfg: RecognizeConfig) -> tuple[ShapeKind, Element | None]:
    if isinstance(element, PathElem):
        pts = flatten_path_commands(element.d)
    elif isinstance(element, PolylineElem):
        pts = list(element.points)
    elif isinstance(element, (LineElem, RectElem, CircleElem, EllipseElem,
                              PolygonElem, Text, TextPath, Group, Layer)):
        return None
    else:
        return None
    shape = recognize(pts, cfg)
    if shape is None:
        return None
    return shape.kind, recognized_to_element(shape, element)
